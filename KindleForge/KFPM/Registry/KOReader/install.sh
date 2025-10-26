#!/bin/sh

set -e

TMPDIR=/mnt/us/KFPM-Temporary
mkdir -p "$TMPDIR"

OTA_SERVER="https://ota.koreader.rocks/"
CHANNEL="stable"

if [ -f /lib/ld-linux-armhf.so.3 ]; then
  OTA_ZSYNC="koreader-kindlehf-latest-$CHANNEL.zsync"
else
  OTA_ZSYNC="koreader-kindlepw2-latest-$CHANNEL.zsync"
fi

OTA_FILENAME=$(curl "$OTA_SERVER$OTA_ZSYNC" -s -r 0-150 | grep Filename | sed 's/Filename: //')

if [ "$OTA_FILENAME" = "" ]; then
  exit 1 # Cannot Find OTA
fi

# Download Nightly
curl -fSL --progress-bar $OTA_SERVER$OTA_FILENAME -s --output $TMPDIR/KoreaderInstall.tar.gz

tar -xf $TMPDIR/KoreaderInstall.tar.gz -C /mnt/us/

# Download Scriptlet
curl -fSL --progress-bar -o /mnt/us/documents/koreader.sh https://raw.githubusercontent.com/KindleTweaks/KindleForge/refs/heads/master/KFPM/Registry/KOReader/assets/koreader.sh

# Cleanup
rm -rf $TMPDIR

exit 0
