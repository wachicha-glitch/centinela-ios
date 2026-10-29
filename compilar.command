#!/bin/bash
# Doble clic (clic derecho → Abrir la primera vez): compila Centinela y crea Centinela.ipa sin firmar para Sideloadly.
cd "$(dirname "$0")" || exit 1
XCODE="/Applications/Xcode.app/Contents/Developer"
terminar() { echo; read -n 1 -s -r -p "Pulsa cualquier tecla para cerrar."; echo; exit "$1"; }
[ -d "$XCODE" ] || { echo "No encuentro Xcode en Aplicaciones."; terminar 1; }
echo "1/3 · Preparando Xcode. Te pedirá la contraseña del Mac (no se ve al escribirla)."
sudo xcode-select -s "$XCODE" || terminar 1
sudo xcodebuild -license accept >/dev/null 2>&1
sudo xcodebuild -runFirstLaunch >/dev/null 2>&1
echo "2/3 · Compilando…"
rm -rf build Payload "Centinela.ipa" build.log
xcodebuild \
  -project "Centinela.xcodeproj" \
  -target "Centinela" \
  -configuration Release \
  -sdk iphoneos \
  SYMROOT="$PWD/build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build > build.log 2>&1
if [ ! -d "build/Release-iphoneos/Centinela.app" ]; then
  echo "No se ha podido compilar. Errores:"; grep -E "error:|fatal|requires" build.log | head -20
  echo "Haz una captura de esta ventana y mándasela a Claude."; terminar 1
fi
echo "3/3 · Creando Centinela.ipa"
mkdir -p Payload && cp -R "build/Release-iphoneos/Centinela.app" Payload/ && zip -qry "Centinela.ipa" Payload && rm -rf Payload
echo "¡Hecho! Instálalo en el iPhone con Sideloadly."
open -R "Centinela.ipa"
terminar 0
