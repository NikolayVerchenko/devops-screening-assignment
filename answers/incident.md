# Incident analysis

## Первые пять команд

 1. `docker compose -f docker-compose.prod.yml ps` — гипотеза/ожидаемый сигнал: проблема локализована в API; ожидаю увидеть `api` в состоянии `Restarting`, при этом `db` — `healthy`, а `nginx` — `Up`.

2. `docker inspect "$(docker compose -f docker-compose.prod.yml ps -q api)" --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} RestartCount={{.RestartCount}}'` — гипотеза/ожидаемый сигнал: API завершается из-за OOM; ожидаю `OOMKilled=true`, `ExitCode=137` и рост `RestartCount`.

3. `free -m` — гипотеза/ожидаемый сигнал: на VM исчерпана доступная память и отсутствует swap; ожидаю около `180 MiB available` при `3930 MiB total` и `0 MiB swap`.

4. `git diff a81f9c2^ a81f9c2 -- docker-compose.prod.yml` — гипотеза/ожидаемый сигнал: OOM вызван изменением конфигурации в последнем релизе; ожидаю увидеть увеличение `WEB_CONCURRENCY` с `2` до `16`.

5. `journalctl -k --since "14:00" --until "14:10" | grep -iE 'out of memory|oom|killed process'` — гипотеза/ожидаемый сигнал: Node.js был убит OOM Killer хоста; ожидаю сообщение ядра `Out of memory: Killed process ... (node)` около времени падения API.

## Основная причина

В релизе `a81f9c2` параметр `WEB_CONCURRENCY` был увеличен с `2` до `16` на VM с `2 vCPU` и `4 GiB RAM`. После релиза возник дефицит памяти: доступно около `180 MiB`, swap отсутствует. Ядро завершило процесс Node.js через OOM Killer, что подтверждается `OOMKilled=true`, `ExitCode=137` и сообщением `Out of memory: Killed process ... (node)`. Из-за падений и перезапусков API Nginx периодически терял upstream и возвращал пользователям `502 Bad Gateway`.

## Вторичные риски

- Корневой раздел заполнен на `92%` (`35 GiB` из `40 GiB`). При дальнейшем заполнении диска возможны проблемы с записью логов, работой Docker и PostgreSQL.
- `/var/lib/docker/containers` занимает `11 GiB`, что указывает на значительный объём container logs. Без настроенной ротации логов они могут продолжить рост и привести к исчерпанию дискового пространства.

## Первое mitigation

Откатить API на предыдущую стабильную версию с `WEB_CONCURRENCY=2`, не затрагивая контейнер PostgreSQL и его volume. Это устраняет изменение, после которого начался OOM, и позволяет быстрее всего восстановить доступность API в пределах допустимого downtime.

## Rollback plan

1. Определить предыдущую стабильную версию API и убедиться, что соответствующий image доступен в registry.
2. Вернуть конфигурацию API к `WEB_CONCURRENCY=2` и указать предыдущий стабильный image явно, без использования `latest`.
3. Пересоздать только сервис API: `docker compose -f docker-compose.prod.yml up -d --no-deps api`. PostgreSQL и его volume не останавливать и не удалять.
4. Проверить `docker compose -f docker-compose.prod.yml ps`, health endpoint API и внешний endpoint через Nginx.
5. Проверить, что `RestartCount` API не увеличивается, новых OOM-событий нет, а error rate и p95 возвращаются к значениям до релиза (`0.2%` и `220 ms`) или к согласованному допустимому уровню.
6. Если предыдущий image недоступен, как минимальную аварийную меру вернуть `WEB_CONCURRENCY=2` для текущего image и пересоздать только API, после чего выполнить те же проверки.

## Приоритеты

### P0
1. `WEB_CONCURRENCY=16` на VM с `2 vCPU` и `4 GiB RAM` приводит к memory pressure, OOM kill Node.js, перезапускам API и пользовательским `502`.
2. Deployment выполняет `docker compose down -v`, что может удалить named volume `db-data` и привести к потере данных PostgreSQL.
3. Pipeline имеет порядок `deploy → test → build`: production deployment выполняется до тестов и сборки нового image.

### P1
4. Контейнеры не имеют resource limits, поэтому не гарантируется резерв минимум `500 MiB` RAM для ОС.
5. `PROD_SSH_PRIVATE_KEY` выводится через `echo` в CI job log, создавая риск утечки production credentials.
6. Использование `latest` для API и deployment не связывает релиз с конкретным immutable image и делает rollback непредсказуемым.
7. PostgreSQL и API публикуют порты `5432` и `3000` на host, хотя внешний доступ требуется только через Nginx; доступ к backend-сервисам следует оставить внутри Docker network.

### P2
8. Корневой диск заполнен на `92%`, `/var/lib/docker/containers` занимает `11 GiB`, в предоставленном Compose не задана ротация container logs.

