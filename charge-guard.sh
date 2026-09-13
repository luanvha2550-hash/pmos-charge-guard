#!/bin/sh
# =========================
# Charge Guard v4 - Bateria Degradada + Auto-Recovery
# - Alvo: 75% | Safe Min: 40%
# - Detecta bug PM660 (charger=Charging mas battery=Discharging)
#   e faz unbind/rebind do driver para recuperar
# =========================

FAST_CHARGE=1200000   # 1.2A
STEP_BASE=350000      # 75-80%
STEP_MID=250000       # 80-85%
STEP_HIGH=150000      # >85%

TARGET_TOP=75
TARGET_LOW=70
SAFE_MIN=40

CHG_DIR="/sys/class/power_supply/pm660-charger"
BAT_DIR="/sys/class/power_supply/qcom-battery"
KNOB="$CHG_DIR/current_max"

# Driver PM660 para reset
CHG_DRIVER="qcom-smbx-charger"
CHG_DEVICE="800f000.spmi:pmic@0:charger@1000"
CHG_DRIVER_PATH="/sys/bus/platform/drivers/$CHG_DRIVER"

# Contagem de leituras consecutivas com bug
BUG_COUNT=0
BUG_THRESHOLD=3       # Depois de 3 leituras consecutivas com bug, faz recovery
RECOVERY_COOLDOWN=120  # Segundos entre tentativas de recovery
LAST_RECOVERY=0

log() { echo "[charge-guard] $1"; }

read_knob() { timeout 2 cat "$KNOB" 2>/dev/null || echo "0"; }
set_knob() {
  REQ="$1"
  CUR="$(read_knob)"
  [ "$CUR" = "$REQ" ] && return 0
  echo "$REQ" > "$KNOB" 2>/dev/null
  NEW="$(read_knob)"
  [ "$NEW" != "$CUR" ] && log "Ajuste: ${CUR}uA -> ${NEW}uA"
}

# Recovery: unbind/rebind do driver PM660
# Simula o efeito de tirar e colocar na tomada
pm660_recovery() {
  NOW=$(date +%s)
  ELAPSED=$(( NOW - LAST_RECOVERY ))
  if [ "$ELAPSED" -lt "$RECOVERY_COOLDOWN" ]; then
    log "Recovery em cooldown (${ELAPSED}s/${RECOVERY_COOLDOWN}s). Aguardando."
    return 1
  fi

  log "RECOVERY: Bug PM660 detectado. Fazendo unbind/rebind do driver..."

  # Unbind
  if ! echo "$CHG_DEVICE" > "$CHG_DRIVER_PATH/unbind" 2>/dev/null; then
    log "RECOVERY FALHOU: Nao conseguiu fazer unbind."
    return 1
  fi
  sleep 3

  # Rebind
  if ! echo "$CHG_DEVICE" > "$CHG_DRIVER_PATH/bind" 2>/dev/null; then
    log "RECOVERY FALHOU: Nao conseguiu fazer rebind. CRITICO!"
    return 1
  fi
  sleep 5

  # Verifica se funcionou
  CHG_STATUS=$(timeout 2 cat "$CHG_DIR/status" 2>/dev/null)
  BAT_STATUS=$(timeout 2 cat "$BAT_DIR/status" 2>/dev/null)

  if [ "$BAT_STATUS" = "Charging" ]; then
    log "RECOVERY OK: Bateria reportando Charging novamente!"
    BUG_COUNT=0
    LAST_RECOVERY=$NOW
    return 0
  else
    log "RECOVERY PARCIAL: Charger=$CHG_STATUS Battery=$BAT_STATUS. Pode precisar replug fisico."
    LAST_RECOVERY=$NOW
    return 1
  fi
}

[ -w "$KNOB" ] || { log "ERRO: $KNOB inacessivel"; exit 1; }
log "Iniciando v4. Alvo: $TARGET_TOP% | Safe: $SAFE_MIN% | Auto-recovery: ON"

FORCE_MODE=1

while true; do
  # Leitura com timeout para evitar travamentos
  CAP=$(timeout 2 cat "$BAT_DIR/capacity" 2>/dev/null)
  CHG_STATUS=$(timeout 2 cat "$CHG_DIR/status" 2>/dev/null)
  BAT_STATUS=$(timeout 2 cat "$BAT_DIR/status" 2>/dev/null)
  CHG_ONLINE=$(timeout 2 cat "$CHG_DIR/online" 2>/dev/null)

  if [ -z "$CAP" ]; then sleep 5; continue; fi

  # ========================================
  # DETECCAO DO BUG PM660
  # Se charger diz Charging/online mas battery diz Discharging
  # ========================================
  if [ "$CHG_ONLINE" = "1" ] && [ "$BAT_STATUS" = "Discharging" ] && [ "$CHG_STATUS" = "Charging" ]; then
    BUG_COUNT=$((BUG_COUNT + 1))
    log "Bug PM660 detectado ($BUG_COUNT/$BUG_THRESHOLD): charger=$CHG_STATUS battery=$BAT_STATUS cap=$CAP%"

    if [ "$BUG_COUNT" -ge "$BUG_THRESHOLD" ]; then
      pm660_recovery
      # Nao ajusta corrente agora, espera proximo ciclo
      sleep 15
      continue
    fi
  else
    # Reset contador se voltou ao normal
    if [ "$BUG_COUNT" -gt 0 ]; then
      log "Bug PM660 resolvido sozinho (era $BUG_COUNT leituras)."
      BUG_COUNT=0
    fi
  fi

  # ========================================
  # Logica normal de carregamento
  # ========================================

  # 1. Failsafe (Bateria Ruim)
  if [ "$CAP" -le "$SAFE_MIN" ]; then
     [ "$FORCE_MODE" -eq 0 ] && log "CRITICO: $CAP%. Forcando Carga."
     set_knob "$FAST_CHARGE"
     FORCE_MODE=1
     sleep 10
     continue
  fi

  # 2. Histerese
  if [ "$CAP" -le "$TARGET_LOW" ]; then
     if [ "$FORCE_MODE" -eq 0 ]; then
        log "Baixo ($CAP%). Ativando Carga Forte."
        FORCE_MODE=1
     fi
  elif [ "$CAP" -ge "$TARGET_TOP" ]; then
     if [ "$FORCE_MODE" -eq 1 ]; then
        log "Alvo ($CAP%). Ativando Steps."
        FORCE_MODE=0
     fi
  fi

  # 3. Aplica Corrente
  if [ "$FORCE_MODE" -eq 1 ]; then
     set_knob "$FAST_CHARGE"
  else
     if [ "$CAP" -ge 85 ]; then set_knob "$STEP_HIGH"
     elif [ "$CAP" -ge 80 ]; then set_knob "$STEP_MID"
     else set_knob "$STEP_BASE"
     fi
  fi

  sleep 15
done