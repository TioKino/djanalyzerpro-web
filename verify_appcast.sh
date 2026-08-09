#!/usr/bin/env bash
# ============================================================
# VERIFICADOR DEL APPCAST — correr ANTES de publicar
# ============================================================
#
# Por qué existe (auditoría 2026-08-09): los 12 <enclosure> del appcast apuntan
# a solo DOS URLs — DJAnalyzerPro.dmg y DJAnalyzerPro-Setup.zip — que son alias
# MUTABLES, mientras cada item declara su propio `length` y su propia
# `sparkle:edSignature`. Sparkle valida ambos contra el fichero que descarga,
# así que como mucho UN item de cada plataforma puede ser consistente, y en
# cada release hay una ventana en la que ninguno lo es:
#
#   subes el DMG antes que el XML -> el cliente descarga el binario nuevo y lo
#                                    verifica contra la firma vieja -> falla
#   subes el XML antes que el DMG -> al revés -> falla
#
# En los dos casos el auto-update se rompe EN SILENCIO: Sparkle descarta la
# actualización y el usuario nunca se entera de que existe.
#
# ARREGLO DE FONDO: que los <enclosure> apunten a URLs VERSIONADAS e inmutables
# (DJAnalyzerPro-2.9.7.dmg), dejando el alias estable solo para el botón
# "Descarga directa" de la web. Este script comprueba que se cumple y que cada
# enclosure casa con el fichero real.
#
# USO:
#   ./verify_appcast.sh                  # verifica el appcast.xml local
#   ./verify_appcast.sh https://www.djanalyzerpro.com/appcast.xml
#
# Salida distinta de 0 = NO publicar.

set -uo pipefail

APPCAST="${1:-appcast.xml}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ "$APPCAST" == http* ]]; then
    echo "Descargando $APPCAST…"
    curl -fsSL "$APPCAST" -o "$TMP/appcast.xml" || { echo "ERROR: no se pudo descargar"; exit 1; }
    APPCAST="$TMP/appcast.xml"
fi

[ -f "$APPCAST" ] || { echo "ERROR: no existe $APPCAST"; exit 1; }

echo "Verificando $APPCAST"
echo ""

# Extrae url|length|os de cada enclosure (una línea por enclosure).
mapfile -t ENCLOSURES < <(
    tr '\n' ' ' < "$APPCAST" \
      | grep -oE '<enclosure[^>]*>' \
      | while read -r tag; do
            url=$(grep -oE 'url="[^"]*"' <<< "$tag" | head -1 | cut -d'"' -f2)
            len=$(grep -oE 'length="[^"]*"' <<< "$tag" | head -1 | cut -d'"' -f2)
            os=$(grep -oE 'sparkle:os="[^"]*"' <<< "$tag" | head -1 | cut -d'"' -f2)
            echo "${url}|${len}|${os}"
        done
)

total=${#ENCLOSURES[@]}
echo "Enclosures encontrados: $total"
echo ""

# ── 1. URLs mutables compartidas entre versiones ────────────────────────
echo "── URLs duplicadas (alias mutables) ──"
dupes=0
while read -r count url; do
    if [ "$count" -gt 1 ]; then
        echo "  AVISO: $count enclosures comparten $url"
        echo "         Solo uno puede casar con el fichero servido. Usa URLs"
        echo "         versionadas (…-2.9.7.dmg) en los enclosure."
        dupes=$((dupes + 1))
    fi
done < <(printf '%s\n' "${ENCLOSURES[@]}" | cut -d'|' -f1 | sort | uniq -c | sort -rn)
[ "$dupes" -eq 0 ] && echo "  OK: cada enclosure tiene su URL propia."
echo ""

# ── 2. Cada enclosure casa con el fichero real ──────────────────────────
echo "── Contraste contra el hosting ──"
fails=0
checked=0
declare -A SEEN
for row in "${ENCLOSURES[@]}"; do
    url="${row%%|*}"
    rest="${row#*|}"
    declared="${rest%%|*}"
    os="${rest##*|}"

    # Una URL repetida solo se comprueba una vez; el aviso ya salió arriba.
    [ -n "${SEEN[$url]:-}" ] && continue
    SEEN[$url]=1
    checked=$((checked + 1))

    actual=$(curl -fsSLI "$url" 2>/dev/null | tr -d '\r' \
             | awk 'tolower($1) ~ /^content-length:/ {print $2}' | tail -1)

    if [ -z "$actual" ]; then
        echo "  FALLO  [$os] $url"
        echo "         inalcanzable o sin Content-Length"
        fails=$((fails + 1))
    elif [ "$actual" != "$declared" ]; then
        echo "  FALLO  [$os] $url"
        echo "         length declarado: $declared"
        echo "         tamaño real:      $actual"
        echo "         Sparkle rechazará la actualización."
        fails=$((fails + 1))
    else
        echo "  OK     [$os] $(basename "$url") ($actual bytes)"
    fi
done
echo ""

# ── 3. Firmas presentes ─────────────────────────────────────────────────
sigs=$(grep -c 'sparkle:edSignature=' "$APPCAST" || true)
echo "── Firmas ──"
if [ "$sigs" -lt "$total" ]; then
    echo "  FALLO: $sigs firmas para $total enclosures — falta alguna."
    fails=$((fails + 1))
else
    echo "  OK: $sigs firmas para $total enclosures."
    echo "  (La validez criptográfica solo la comprueba Sparkle con la clave"
    echo "   pública de Info.plist; aquí solo se verifica que estén.)"
fi
echo ""

echo "════════════════════════════════════════════"
if [ "$fails" -gt 0 ]; then
    echo "NO PUBLICAR: $fails problema(s) en $checked URL(s) comprobadas."
    exit 1
fi
if [ "$dupes" -gt 0 ]; then
    echo "PUBLICABLE con reservas: $dupes URL(s) compartidas entre versiones."
    echo "Los items antiguos quedarán inconsistentes en cuanto subas la"
    echo "siguiente versión al mismo alias."
    exit 2
fi
echo "TODO OK: appcast consistente con el hosting."
