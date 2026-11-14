#!/bin/zsh
cd -- "$(dirname -- "$0")" || exit 1
if ! command -v npm >/dev/null 2>&1; then
  echo "Necesitas instalar Node.js 24.12 o posterior para abrir Dark Sector."
  echo "Descárgalo desde https://nodejs.org y vuelve a abrir este archivo."
  read -r "?Pulsa Intro para cerrar."
  exit 1
fi
if [ ! -d node_modules ]; then
  echo "Preparando Dark Sector por primera vez..."
  npm ci || exit 1
fi
echo "Abriendo Dark Sector. Mantén esta ventana abierta. Para detenerlo: Control + C."
npm run dev -- --open
