#!/usr/bin/env bash
set -o errexit -o errtrace -o functrace -o nounset -o pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]:-$PWD}")" 2>/dev/null 1>&2 && pwd)"
readonly root
# shellcheck source=/dev/null
. "$root/helpers.sh"
# shellcheck source=/dev/null
. "$root/mdns.sh"

helpers::dir::writable /tmp
helpers::dir::writable /data
# /tmp/runtime
helpers::dir::writable "$XDG_RUNTIME_DIR/avahi-daemon"

# mDNS blast if asked to
[ "${MOD_MDNS_ENABLED:-}" != true ] || {
  [ ! "${MOD_MDNS_STATION:-}" ] || mdns::records::add "_workstation._tcp" "$MOD_MDNS_HOST" "${MOD_MDNS_NAME:-}" "$PORT"
  mdns::records::add "${ADVANCED_MOD_MDNS_TYPE:-_http._tcp}" "$MOD_MDNS_HOST" "${MOD_MDNS_NAME:-}" "$PORT"
  mdns::start::broadcaster
}

export STEPPATH=/data/step

step::init(){
  local password="$1"
  local name="${2:-dbdbdp super cayan}"
  local dnsname="${3:-ca.local}"
  local addr="${4:-:443}"
  local provisioner="${5:-root@$dnsname}"
  step ca init --deployment-type=standalone --name "$name" --dns "$dnsname" --address="$addr" \
    --provisioner="$provisioner" --password-file <(echo -n "$password") \
    --provisioner-password-file <(echo -n "ignore_this")
  step ca provisioner add acme --type ACME
}

step::root::fingerprint(){
  step certificate fingerprint "$(step path)"/certs/root_ca.crt
}

[ -e /data/step ] || {
  printf >&2 "Need to initialize the CA\n"
  #printf "%s" "$PROVISIONER_PASSWORD" > /data/provisioner_password_file
  CA_NAME=dbdbdp
  PROVISIONER=root@ca.local
  # Password is used both by the root and the intermediate?
  step::init "$PROVISIONER_PASSWORD" "$CA_NAME" "$MOD_MDNS_HOST.local" ":$PORT" "$PROVISIONER"
#  step ca init --deployment-type=standalone --name "$CA_NAME" --dns "$MOD_MDNS_HOST".local --address=:"$PORT" --provisioner=$PROVISIONER --password-file <(echo -n "$PROVISIONER_PASSWORD")
}

[ "${MOD_MDNS_NSS_ENABLED:-}" != true ] || mdns::start::avahi

exec step-ca "$(step path)"/config/ca.json --password-file <(echo -n "$PROVISIONER_PASSWORD") "$@"
