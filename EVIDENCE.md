# keepalive 再利用 race による散発502

front nginx が upstream への keepalive 接続をプールしている状態で、backend 側が接続を閉じた直後にその接続を再利用すると502になる。本番で「再現しない」とされる散発502の一つ。

## 環境

- nginx 1.29.1（Debian 12.12 ベースの公式イメージ）
- Linux 6.12.54-linuxkit aarch64（Docker Desktop、macOS ホスト）
- front（`127.0.0.1:8080`、worker 4、`keepalive 16`）→ backend（`127.0.0.1:8081`、worker 2）。同一コンテナ内の loopback
- 負荷は `ab -k -c 64 -n 70000`。所要 3.6 秒、19,369 req/s
- backend を 0.4 秒ごとに `nginx -s reload`。負荷が走っている 3.6 秒のあいだに 9 回

再現手順は `run.sh`。設定は `conf/`、各シナリオの生ログは `out/<シナリオ>/`。

```
docker build -t keepalive-lab .
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW -v "$PWD":/lab keepalive-lab bash /lab/run.sh baseline-concurrent
```

## シナリオと結果

| シナリオ | 条件 | リクエスト | 502 | error log |
|---|---|---|---|---|
| baseline-concurrent | 64並行 + reload、`proxy_next_upstream off` | 70,000 | 273〜305 | 同数 |
| baseline-sequential | 1本ずつ（間に0.15秒）+ 同じ reload | 400 | 0 | 0 |
| retry-get | `proxy_next_upstream` 既定 + GET | 70,000 | 0 | 478 |
| retry-post | `proxy_next_upstream` 既定 + POST | 70,000 | 237 | 237 |
| ka-timeout | front の upstream に `keepalive_timeout 5s` | 70,000 | 303 | 303 |
| idle-close | reload なし、backend の `keepalive_timeout 1s`、負荷を1.5秒おきに断続 | 40,000 | 0 | 0 |
| nonidem-post | `proxy_next_upstream error timeout non_idempotent` + POST | 70,000 | 0 | 405 |
| backend-noka | backend の `keepalive_timeout 0`（応答ごとに Connection: close） | 70,000 | 0 | 0 |
| baseline-20s | 20秒の負荷 + reload 50回（drain との比較用） | 381,087 | 2,236 | 2,236 |
| drain | 20秒の負荷 + 退役側を先に外してから停止、19回 | 382,582 | 0 | 0 |

baseline-concurrent は4回走らせて 273 / 297 / 303 / 305。run ごとに動くので固定値では書かない。

## 分かったこと

並行負荷が条件。同じ reload をかけても、1本ずつ投げると502は出ない（400件で0）。front の worker が忙しく、届いた FIN をまだ処理していない瞬間にプールから同じ接続を取り出したときだけ起きる。暇なら FIN を先に処理してプールから捨てる。

再送は502を消すが失敗は消さない。`proxy_next_upstream` を既定に戻すと GET の502はゼロになるが、error log には478件残る。

クライアントの1リクエストと backend への試行は1対1ではない。アクセスログに `$upstream_addr` と `$upstream_status` を出すと、1行に複数の試行が並ぶ。

```
1787042097.147 200 0.002 127.0.0.1:8081, 127.0.0.1:8081, 127.0.0.1:8081, 127.0.0.1:8081 502, 502, 502, 200 GET / HTTP/1.0
```

7万リクエストのうち再送が記録された行は389。内訳は2回試行が315、3回が60、4回が13、5回が1。失敗した試行の合計は478で、error log の行数と一致する。error log の1行はリクエストではなく試行を記録している。

既定の `combined` 形式には `$upstream_status` が含まれないので、この記録は出ていても見えない。

再送の代償はレイテンシ。`$request_time` は再送の無い行が中央値3ms・p99 6ms、再送があった行が中央値5ms・p99 27ms・最大33ms。

POST は再送されない。既定の `proxy_next_upstream` は非冪等メソッドを再送しない（`non_idempotent` を明示しない限り）。同じ条件で GET が0件、POST が237件。「502が特定のエンドポイントだけに出る」の一因になる。

front 側の `keepalive_timeout` は reload 起因に効かない。upstream ブロックに 5s を入れても 303 件で、baseline のばらつきの範囲内。reload は待たずに FIN を送るので、front がプールを保持する時間とは無関係。

idle timeout だけでは出なかった。reload をかけず backend の `keepalive_timeout` を 1s にして、負荷を1.5秒おきに断続させても0件。接続が idle であるためには front が暇である必要があり、暇なら FIN を即座に処理する。二つの条件が同時に立ちにくい。

## 効いた対策と、その代償

退役させる backend を先に front の upstream から外し、front を reload して旧 worker が消えてからプロセスを落とす（drain）。20秒で19回入れ替えて502も error log もゼロ。同じ20秒で reload を50回かけた baseline-20s は2,236件。プールは維持したまま消える。代償は手順で、backend を2系統用意して front の設定を差し替える必要がある。

backend の `keepalive_timeout` を 0 にして応答ごとに `Connection: close` を返させる。502も失敗もゼロ。front がプールしないので窓が生まれない。代償は接続数で、`TcpActiveOpens` が 70,128。baseline の 722 に対して約100倍、1リクエスト1接続に戻る。

`proxy_next_upstream` に `non_idempotent` を足して POST も再送させる。502はゼロになるが error log には405件残る。失敗は起きていて再送で通しているだけ。この経路では二重実行は観測されなかった。backend が受けた回数が 70,000 で、クライアントの送信数と一致している。接続が閉じたあとに書き込んで応答が返らなかったケースなので、backend はリクエストを読んでいない。

## 採取したシグネチャ

error log は2種類に割れる。件数の比は run で動く。

```
upstream prematurely closed connection while reading response header from upstream
recv() failed (104: Connection reset by peer) while reading response header from upstream
```

baseline-concurrent（502が297件）の内訳は前者287件、後者10件。

nstat の差分（502件数と連動するが一致はしない）。

```
TcpEstabResets                  307
TcpOutRsts                      297
TcpExtTCPAbortOnData            284
```

tcpdump（loopback、`tcp port 8081`）。同一の4タプルで FIN →次のリクエスト→ RST の並びが 285 接続で取れた。502は297件なので、全部は取れていない。

- backend の FIN から front の次リクエスト（PSH）まで：中央値 904µs、範囲 3〜3,449µs
- 次リクエストから RST まで：中央値 2µs、最大 7µs

reload と502の時刻差。502は直前の reload から 100〜107ms に集まる（297件すべて。中央値101ms、100ms未満はゼロ）。この下限は4回の run で動かない。

束の形。9回の reload に対して1回あたり24〜39件（中央値34）。1回ぶんの502は1ミリ秒の幅に収まる（reload#0 は最初が100ms後、最後が101ms後）。散発ではなく、reload ごとの spike。

## 分からなかったこと

- 100ms の下限が何に由来するかは追っていない。nginx 側のタイマーか、reload 後に旧 worker が idle 接続を閉じるまでの待ちかを特定していない
- `recv() failed (104)` が出る条件と `prematurely closed` になる条件の分かれ目を特定していない。件数比は run ごとに 3〜10 件の幅で動く
- idle timeout 起因は、このラボの比率（idle 1s、負荷の切れ目 1.5秒）では出なかっただけ。切れ目と timeout の比を変えた場合は試していない。プールの接続数が多く使われ方に偏りがあれば、front が他の接続で忙しいまま特定の1本だけ idle になる状況は理屈の上ではありうる。作れていないので「起きない」とは書かない
- ホストは macOS 上の Docker Desktop（linuxkit VM）。ベアメタルの Linux では数値が動く可能性がある
- `non_idempotent` の再送で二重実行が起きないと言えるのは、backend がリクエストを読む前に閉じた場合だけ。backend が処理を終えてから応答が失われる経路はこのラボでは作れていない。その場合は再送が二重実行になる
- drain は front を reload する手順のため、クライアント側の keepalive 接続が切れる。`ab` は `-r` を付けないとそこで打ち切る（最初の drain 実行がこれで7,667件で終わった）。クライアント側への影響は測っていない
- 実運用の発生率は測っていない。ここでの 0.4% は 0.4 秒ごとに reload し続けた場合の値で、本番の reload はデプロイのときだけになる

## out/ に残しているもの

シナリオごとに `summary.txt`（件数と内訳）、`front-error.log`（全行）、`front-access-non200.log`（502だけ）、`front-access.log.gz`（全リクエスト）、`nstat.txt`、`ab.log`、`reload-times.txt`、使った設定のコピー。

パケットの生キャプチャ（各20MB前後）はコミットしていない。`run.sh` を走らせれば `out/<シナリオ>/loopback.pcap` に再生成される。代わりに `out/baseline-concurrent/loopback-reset-flows.txt` に、RST まで至った接続の全パケット行を10接続ぶん残した。

`retry-get` / `retry-post` / `ka-timeout` / `idle-close` のアクセスログは combined 形式（$msec を入れる前に走らせたため）。`baseline-concurrent` / `baseline-sequential` は `$msec $status $request_time $upstream_addr $upstream_status $request`。
