# Incident packet

## Система

Production работает на одной Ubuntu VM:

- 2 vCPU;
- 4 GiB RAM;
- swap отсутствует;
- диск 40 GiB;
- Docker Compose;
- Nginx → Node.js API → PostgreSQL.

До релиза:

- error rate: `0.2%`;
- p95 latency: `220 ms`.

Через несколько минут после релиза:

- error rate: `12%`;
- p95 latency: `2.8 s`;
- API периодически перезапускается;
- пользователи получают `502 Bad Gateway`.

## Ограничения

- Допустимый downtime — не более 5 минут.
- Данные PostgreSQL нельзя потерять.
- Нельзя переносить систему в Kubernetes или подключать новые managed services.
- ОС должна получить минимум `500 MiB` RAM.
- Решение должно поддерживать rollback.

## Timeline

```text
14:02:11 deploy started, commit=a81f9c2
14:04:38 new containers started
14:07:03 nginx: upstream prematurely closed connection
14:07:04 api container exited with code 137
14:07:06 api container restarted
14:08:21 kernel: Out of memory: Killed process 18422 (node)
```

## Наблюдаемое состояние

```text
$ docker compose ps

NAME          SERVICE   STATUS                          PORTS
shop-api-1    api       Restarting (137) 8 seconds ago  0.0.0.0:3000->3000/tcp
shop-db-1     db        Up 41 days (healthy)            0.0.0.0:5432->5432/tcp
shop-nginx-1  nginx     Up 41 days                      0.0.0.0:80->80/tcp
```

```text
$ docker inspect "$(docker compose ps -q api)" --format \
  'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} RestartCount={{.RestartCount}}'

OOMKilled=true ExitCode=137 RestartCount=7
```

```text
$ free -m

              total   used   free   available
Mem:           3930   3610    120         180
```

```text
$ df -h /

Filesystem      Size  Used Avail Use%
/dev/sda1        40G   35G  3.1G  92%
```

```text
$ sudo du -sh /var/lib/docker/containers

11G     /var/lib/docker/containers
```

```diff
$ git diff a81f9c2^ a81f9c2 -- docker-compose.prod.yml

-      WEB_CONCURRENCY: "2"
+      WEB_CONCURRENCY: "16"
```

Все приведённые данные относятся к одному production deployment.
