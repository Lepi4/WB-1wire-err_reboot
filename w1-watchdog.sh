#!/usr/bin/env bash
set -euo pipefail

BUS_MASTER="${BUS_MASTER:-/sys/bus/w1/devices/w1_bus_master1}"
SENSOR_GLOB="${SENSOR_GLOB:-28-*}"
TEMP_FILE="${TEMP_FILE:-temperature}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
STATE_FILE="${STATE_FILE:-/run/w1-watchdog.state}"
POWER_CYCLE_DELAY_SEC="${POWER_CYCLE_DELAY_SEC:-5}"
POST_POWER_CYCLE_DELAY_SEC="${POST_POWER_CYCLE_DELAY_SEC:-10}"
POWER_OFF_CMD="${POWER_OFF_CMD:-}"
POWER_ON_CMD="${POWER_ON_CMD:-}"
LOG_TAG="${LOG_TAG:-w1-watchdog}"
STDOUT="${STDOUT:-0}"
LOG_TO_SYSLOG="${LOG_TO_SYSLOG:-1}"
OK_LOG_INTERVAL_SEC="${OK_LOG_INTERVAL_SEC:-300}"
OK_LOG_EVERY_RUN="${OK_LOG_EVERY_RUN:-1}"
OK_STATE_FILE="${OK_STATE_FILE:-/run/w1-watchdog.ok}"

log() {
  if [[ "$STDOUT" == "1" ]]; then
    echo "[$LOG_TAG] $*"
  fi

  if [[ "$LOG_TO_SYSLOG" == "1" ]] && command -v logger >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "$*"
  fi
}

read_counter() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

write_counter() {
  local val="$1"
  printf "%s" "$val" > "$STATE_FILE"
}

read_ok_ts() {
  if [[ -f "$OK_STATE_FILE" ]]; then
    cat "$OK_STATE_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

write_ok_ts() {
  local val="$1"
  printf "%s" "$val" > "$OK_STATE_FILE"
}

check_sensors() {
  shopt -s nullglob
  local files=("$BUS_MASTER"/$SENSOR_GLOB/$TEMP_FILE)
  if (( ${#files[@]} == 0 )); then
    return 1
  fi

  local f
  for f in "${files[@]}"; do
    if ! value=$(cat "$f" 2>/dev/null); then
      return 1
    fi
    if [[ -z "$value" ]]; then
      return 1
    fi
  done

  return 0
}

power_cycle() {
  if [[ -z "$POWER_OFF_CMD" || -z "$POWER_ON_CMD" ]]; then
    log "POWER_OFF_CMD/POWER_ON_CMD не заданы, power-cycle пропущен"
    return 1
  fi

  log "power-cycle 1-wire: OFF"
  bash -c "$POWER_OFF_CMD"
  sleep "$POWER_CYCLE_DELAY_SEC"
  log "power-cycle 1-wire: ON"
  bash -c "$POWER_ON_CMD"
  log "power-cycle 1-wire: DONE"
  if (( POST_POWER_CYCLE_DELAY_SEC > 0 )); then
    log "post power-cycle delay: ${POST_POWER_CYCLE_DELAY_SEC}s"
    sleep "$POST_POWER_CYCLE_DELAY_SEC"
  fi
}

main() {
  local counter
  counter=$(read_counter)

  if check_sensors; then
    if [[ "$OK_LOG_EVERY_RUN" == "1" ]]; then
      log "датчики доступны"
    else
      local now last_ok
      now=$(date +%s)
      last_ok=$(read_ok_ts)
      if (( now - last_ok >= OK_LOG_INTERVAL_SEC )); then
        log "датчики доступны"
        write_ok_ts "$now"
      fi
    fi
    if [[ "$counter" != "0" ]]; then
      log "датчики восстановились, сброс счётчика ошибок"
    fi
    write_counter 0
    exit 0
  fi

  counter=$((counter + 1))
  write_counter "$counter"
  if (( counter == 1 )); then
    log "ошибка чтения 1-wire (счётчик: $counter/$FAIL_THRESHOLD)"
  fi

  if (( counter >= FAIL_THRESHOLD )); then
    log "превышен порог ошибок, выполняю power-cycle"
    power_cycle || true
    write_counter 0
  fi
}

main "$@"
