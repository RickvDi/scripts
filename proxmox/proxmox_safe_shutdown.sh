#!/usr/bin/env bash
# Proxmox Safe Shutdown Script (robust version)
# - Wacht op kritieke taken (vzdump, zfs scrub, pve-zsync/replicatie, rsync)
# - Sluit alleen af bij lage load
# - Stopt VM's en containers netjes
# - Exporteert ZFS veilig
# - Stuurt e-mail bij fouten én succes via `mail` (msmtp)

set -euo pipefail
IFS=$'\n\t'
PATH=$PATH:/usr/sbin:/sbin

#####################################
# Config
#####################################
readonly BELANGRIJKE_TAKEN=("vzdump" "zfs" "pvesr" "rsync" "pve-zsync")
readonly MAX_LOAD="1.5"            # max 1-min load average
readonly CHECK_INTERVAL=300        # 5 min
readonly NODE="$(hostname)"
readonly ADMIN_EMAIL="admin@ricksictservices.nl"  # pas aan indien nodig
readonly START_HOUR=22             # vanaf 22:00 afsluiten

#####################################
# Helpers
#####################################
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

send_mail() {
  # $1 = subject, $2 = message
  # Vereist dat 'mail' via msmtp werkt (zoals je net hebt ingericht).
  local subject="$1"
  local msg="${2:-}"
  # Bij fouten wil je nooit dat mail een exit veroorzaakt die de trap triggert
  # Daarom: || true
  printf '%s\n' "$msg" | mail -s "$subject" "$ADMIN_EMAIL" || true
}

error_mail_and_exit() {
  # $1 = message
  local msg="$1"
  send_mail "FOUT: Safe Shutdown op $NODE" "$msg"
  log "FOUT: $msg"
  exit 1
}

#####################################
# Preflight checks (commando’s aanwezig?)
#####################################
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || error_mail_and_exit "Vereist commando ontbreekt: $1"
}
need_cmd awk
need_cmd pgrep
need_cmd qm
need_cmd pct
need_cmd zpool
need_cmd mail
need_cmd shutdown

#####################################
# Trap (algemene error handler)
#####################################
trap 'error_mail_and_exit "Onverwachte fout in script (exit code $?) tijdens: $BASH_COMMAND"' ERR

#####################################
# Kernfuncties
#####################################
check_load_ok() {
  # 1-min load (eerste veld) vergelijken met MAX_LOAD
  local load
  load="$(awk "{print \$1}" /proc/loadavg)"
  log "Huidige load: ${load}"
  # bc is niet strikt nodig met awk:
  awk -v l="$load" -v max="$MAX_LOAD" 'BEGIN{exit (l>max)?1:0}'
}

taken_actief() {
  # return 0 als ER taken actief zijn (dus "true" in shell), 1 als NIET
  for taak in "${BELANGRIJKE_TAKEN[@]}"; do
    if pgrep -x "$taak" >/dev/null 2>&1; then
      log "Belangrijke taak actief: $taak"
      return 0
    fi
  done

  # ZFS scrub in progress?
  if zpool status 2>/dev/null | grep -qE 'scrub in progress'; then
    log "ZFS scrub nog bezig."
    return 0
  fi

  # Extra check op vzdump/pve-zsync via ps (zekerheid)
  if pgrep -x -f 'vzdump|pve-zsync' >/dev/null 2>&1; then
    log "Backup/replicatie actief (pgrep-detectie)."
    return 0
  fi

  return 1
}

wacht_tot_taken_klaar() {
  log "Er draaien nog belangrijke taken. Wachten tot voltooid..."
  while taken_actief; do
    sleep "$CHECK_INTERVAL"
  done
  log "Alle belangrijke taken zijn voltooid."
}

sluit_vms_en_cts_af() {
  log "Netjes afsluiten van draaiende VM's en containers..."

  # VMs
  # 'qm list' output: VMID NAME STATUS ...
  while read -r vmid; do
    [ -z "$vmid" ] && continue
    # status kan 'status: running' of alleen 'running' opleveren; we gebruiken 'qm status'
    if qm status "$vmid" 2>/dev/null | grep -q 'running'; then
      log "VM $vmid afsluiten..."
      # skiplock 1 zodat een lock niet blokkeert; timeout 60s
      qm shutdown "$vmid" --timeout 60 --skiplock 1 || send_mail "FOUT: VM shutdown" "VM $vmid kon niet netjes afsluiten op $NODE."
    fi
  done < <(qm list | awk 'NR>1 {print $1}')

  # LXC containers
  while read -r ctid; do
    [ -z "$ctid" ] && continue
    if pct status "$ctid" 2>/dev/null | grep -q 'running'; then
      log "Container $ctid afsluiten..."
      pct shutdown "$ctid" --timeout 60 || send_mail "FOUT: CT shutdown" "Container $ctid kon niet netjes afsluiten op $NODE."
    fi
  done < <(pct list | awk 'NR>1 {print $1}')

  log "Even wachten zodat guests de tijd krijgen om te stoppen..."
  sleep 120
}

exporteer_zfs() {
  log "ZFS pools exporteren (zpool export -a)..."
  zpool export -a || error_mail_and_exit "ZFS export is mislukt op $NODE. Pools zijn mogelijk nog actief!"
}

#####################################
# Main
#####################################
log "=== Proxmox Safe Shutdown gestart op $(date '+%Y-%m-%d %H:%M:%S') ==="

# Alleen uitvoeren vanaf START_HOUR (22)
current_hour="$(date +'%H')"
if [ "$current_hour" -lt "$START_HOUR" ]; then
  log "Het is nog geen ${START_HOUR}:00. Geen actie."
  exit 0
fi

log "Tijdvenster OK (>= ${START_HOUR}:00). Controleer taken en load..."

# Wachten op kritieke taken
if taken_actief; then
  send_mail "Uitstel: taken actief op $NODE" "Shutdown uitgesteld: kritieke taken actief op $NODE. Script wacht tot voltooiing."
  wacht_tot_taken_klaar
fi

# Load moet laag genoeg zijn
if ! check_load_ok; then
  send_mail "Uitstel: hoge load op $NODE" "Shutdown uitgesteld wegens te hoge load (> ${MAX_LOAD}). Probeer later opnieuw."
  log "Shutdown uitgesteld wegens te hoge load."
  exit 1
fi

# Guests netjes afsluiten
sluit_vms_en_cts_af

# ZFS veilig exporteren
exporteer_zfs

# Shutdown host
log "Host afsluiten..."
if shutdown -h now; then
  # NB: deze regel wordt mogelijk niet meer gelogd/gestuurd omdat het systeem direct afsluit.
  send_mail "OK: Safe Shutdown voltooid op $NODE" "Server $NODE is veilig afgesloten op $(date '+%Y-%m-%d %H:%M:%S'). Taken voltooid en ZFS geëxporteerd."
else
  send_mail "FOUT: shutdown faalde op $NODE" "Het shutdown-commando faalde op $NODE. Controleer de host."
  exit 1
fi
