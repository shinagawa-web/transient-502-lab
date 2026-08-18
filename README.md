# keepalive 再利用 race のラボ

リバースプロキシが upstream への keepalive 接続をプールしている状態で、backend がその接続を閉じた直後に再利用すると502になる。本番で「再現しない」とされる散発502の一つ。この現象を再現し、どの対策が効くかを実測するためのラボ。

結果は `EVIDENCE.md`。CI で走らせた生ログは Actions の artifacts に残る。

## 走らせる

```
docker build -t keepalive-lab .
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW -v "$PWD":/lab keepalive-lab bash /lab/run.sh baseline-concurrent
```

出力は `out/<シナリオ>/` に出る。

## シナリオ

| 名前 | 何を見るか |
|---|---|
| baseline-concurrent | 64並行 + backend を0.4秒ごとに reload。素の再現 |
| baseline-sequential | 1本ずつ + 同じ reload。並行負荷が条件であることの対照 |
| retry-get | `proxy_next_upstream` 既定 + GET。再送で502が隠れるか |
| retry-post | 同上 + POST。非冪等メソッドが再送されないか |
| nonidem-post | `non_idempotent` を足して POST も再送させる |
| ka-timeout | front の upstream に `keepalive_timeout 5s`。reload 起因に効くか |
| idle-close | reload なし・backend の idle timeout 1s。デプロイ以外でも出るか |
| baseline-20s | 20秒の負荷 + reload 50回。drain との比較用 |
| drain | 退役側を先に upstream から外してから停止 |

## 構成

front nginx（`127.0.0.1:8080`、worker 4、`keepalive 16`）が backend nginx（`127.0.0.1:8081`、worker 2）に proxy する。両方を1コンテナで動かし、loopback を tcpdump で見る。負荷は `ab`。

`conf/` が設定、`run.sh` がシナリオの実行、`tools/analyze.py` が採取した数値の集計。

## 実行環境について

数値は環境で動く。`EVIDENCE.md` の初回計測は macOS の Docker Desktop（linuxkit VM）で取ったもので、CI（GitHub Actions の ubuntu-latest、4 vCPU / 16GB）で取り直している。nginx は公式イメージで 1.29.1 に固定してあるので、変わるのはホストだけ。
