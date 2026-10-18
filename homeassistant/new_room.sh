#!/bin/bash
# Make the Home Assistant package for one indoor unit.
#   ./new_room.sh "<DeviceName set on the board>" <Topic set on the board>
#   ./new_room.sh "Living room heat pump" gree_living      -> packages/gree_living.yaml
# It also rebuilds packages/gree_homekit.yaml (Apple Home bridge listing every room made so far).
# Then copy the packages folder next to configuration.yaml (see README) and restart Home Assistant.
set -e
if [ $# -ne 2 ]; then echo 'usage: ./new_room.sh "Living room heat pump" gree_living'; exit 1; fi
NAME="$1"; TOPIC="$2"
case "$TOPIC" in *[!a-zA-Z0-9_-]*) echo "Topic may only contain letters, digits, _ and -"; exit 1;; esac
case "$NAME" in *'"'*|*'\'*) echo 'The name may not contain " or \'; exit 1;; esac
# entity-id form of the name, like Home Assistant makes it: accents dropped, lower case, _ between words
SLUG=$(printf '%s' "$NAME" | perl -CS -MUnicode::Normalize -ne 'print lc(NFKD($_) =~ s/\p{Mn}//gr)' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')
SAFE_NAME=$(printf '%s' "$NAME" | sed 's/[&/\]/\\&/g')
cd "$(dirname "$0")"
mkdir -p packages
sed -e '/^#T/d' -e "s/DEVICE_NAME/$SAFE_NAME/g" -e "s/DEVICE_SLUG/$SLUG/g" -e "s/TOPIC/$TOPIC/g" gree_room_template.yaml > "packages/$TOPIC.yaml"
echo "packages/$TOPIC.yaml: climate.$SLUG, switch.${SLUG}_turbo, switch.${SLUG}_display, sensor.${SLUG}_outdoor_energy, automation \"$NAME: follow the unit\""
# Apple Home: rebuild packages/gree_homekit.yaml (one HomeKit Bridge for every room) from the
# "# homekit: <entities> | <name>" line of each room package
HK=packages/gree_homekit.yaml
ROOMS=$(grep -h '^# homekit: ' $(ls packages/*.yaml | grep -v '/gree_homekit.yaml$') | sed 's/^# homekit: //' | sort -t'|' -k2)
{
  sed -e '/^#T/d' gree_homekit_header.yaml
  printf '%s\n' "$ROOMS" | while IFS='|' read -r ENTS RNAME; do
    for E in $ENTS; do echo "        - $E"; done
  done
  echo "    entity_config:"
  printf '%s\n' "$ROOMS" | while IFS='|' read -r ENTS RNAME; do
    set -- $ENTS
    echo "      $1:"
    echo "        name: \"${RNAME# }\""
  done
} > "$HK.tmp"
mv "$HK.tmp" "$HK"
echo "$HK: Apple Home bridge with $(printf '%s\n' "$ROOMS" | grep -c .) room(s)"
echo "Board console:  Backlog DeviceName $NAME; Topic $TOPIC"
