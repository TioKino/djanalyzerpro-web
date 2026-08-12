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
# COMPATIBILIDAD: bash 3.2, que es el que trae macOS. Nada de `mapfile` ni de
# `declare -A` (bash 4+): en el Mac del owner reventaba con
# "mapfile: command not found". Por eso aquí se usan ficheros temporales en
# lugar de arrays asociativos.
#
# USO:
#   ./verify_appcast.sh                  # verifica el appcast.xml local
#   ./verify_appcast.sh https://www.djanalyzerpro.com/appcast.xml
#
# Salida distinta de 0 = NO publicar.

set -eo pipefail

APPCAST="${1:-appcast.xml}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "${APPCAST#http}" != "$APPCAST" ]; then
    echo "Descargando $APPCAST…"
    curl -fsSL "$APPCAST" -o "$TMP/appcast.xml" || { echo "ERROR: no se pudo descargar"; exit 1; }
    APPCAST="$TMP/appcast.xml"
fi

[ -f "$APPCAST" ] || { echo "ERROR: no existe $APPCAST"; exit 1; }

echo "Verificando $APPCAST"
echo ""

# Extrae "url|length|os" de cada enclosure, una línea por enclosure.
#
# Se quitan primero los comentarios XML: el encabezado de appcast.xml habla de
# "<enclosure>" en prosa y el grep lo tomaba por un tag real, dando una entrada
# fantasma sin atributos que además tumbaba el script bajo `set -e`.
# Y se exige `<enclosure ` con espacio, o sea con atributos.
tr '\n' ' ' < "$APPCAST" \
  | sed 's/<!--[^>]*\(-->\)*/ /g; s/<!--.*-->/ /g' \
  | grep -oE '<enclosure [^>]*>' \
  | while IFS= read -r tag; do
        url=$(printf '%s' "$tag" | grep -oE 'url="[^"]*"' | head -1 | cut -d'"' -f2 || true)
        len=$(printf '%s' "$tag" | grep -oE 'length="[^"]*"' | head -1 | cut -d'"' -f2 || true)
        os=$(printf '%s' "$tag" | grep -oE 'sparkle:os="[^"]*"' | head -1 | cut -d'"' -f2 || true)
        [ -z "$url" ] && continue
        printf '%s|%s|%s\n' "$url" "$len" "${os:-?}"
    done > "$TMP/enclosures.txt"

total=$(wc -l < "$TMP/enclosures.txt" | tr -d ' ')
echo "Enclosures encontrados: $total"
echo ""

if [ "$total" -eq 0 ]; then
    echo "ERROR: no se encontró ningún <enclosure>. ¿Es este el appcast correcto?"
    exit 1
fi

# ── 1. URLs mutables compartidas entre versiones ────────────────────────
echo "── URLs duplicadas (alias mutables) ──"
cut -d'|' -f1 < "$TMP/enclosures.txt" | sort | uniq -c | sort -rn > "$TMP/dupes.txt"
dupes=0
while read -r count url; do
    [ -z "$url" ] && continue
    if [ "$count" -gt 1 ]; then
        echo "  AVISO: $count enclosures comparten $url"
        echo "         Solo uno puede casar con el fichero servido. Usa URLs"
        echo "         versionadas (…-2.9.7.dmg) en los enclosure."
        dupes=$((dupes + 1))
    fi
done < "$TMP/dupes.txt"
[ "$dupes" -eq 0 ] && echo "  OK: cada enclosure tiene su URL propia."
echo ""

# ── 2. El item VIVO de cada plataforma casa con el fichero real ─────────
#
# Sparkle solo descarga el item MÁS NUEVO aplicable a la plataforma; los
# anteriores son changelog y nunca se piden. Por eso el contraste duro se hace
# solo sobre el primer enclosure de cada `sparkle:os` (el appcast se ordena con
# lo nuevo arriba). Comprobar también los históricos daría rojo permanente
# —comparten alias, así que sus `length` ya no casan— y una alerta que siempre
# salta se acaba ignorando, que es justo lo que no queremos aquí.
echo "── Item vivo de cada plataforma (lo que Sparkle descarga) ──"
fails=0
checked=0
live_dupes=0
: > "$TMP/seen_os.txt"
: > "$TMP/historicos.txt"
while IFS='|' read -r url declared os; do
    [ -z "$url" ] && continue

    if grep -Fqx "$os" "$TMP/seen_os.txt" 2>/dev/null; then
        printf '%s|%s|%s\n' "$url" "$declared" "$os" >> "$TMP/historicos.txt"
        continue
    fi
    printf '%s\n' "$os" >> "$TMP/seen_os.txt"
    checked=$((checked + 1))

    # ¿Este item VIVO cuelga de una URL compartida con otros? Eso es lo unico
    # que hace falta avisar. Que los historicos compartan el alias es normal y
    # esperado desde la 2.9.8: Sparkle no los descarga nunca.
    if [ "$(cut -d'|' -f1 < "$TMP/enclosures.txt" | grep -Fxc "$url" || true)" -gt 1 ]; then
        live_dupes=$((live_dupes + 1))
    fi

    actual=$(curl -fsSLI "$url" 2>/dev/null | tr -d '\r' \
             | awk 'tolower($1) ~ /^content-length:/ {print $2}' | tail -1 || true)

    if [ -z "$actual" ]; then
        echo "  FALLO  [$os] $url"
        echo "         inalcanzable o sin Content-Length"
        fails=$((fails + 1))
    elif [ "$actual" != "$declared" ]; then
        echo "  FALLO  [$os] $url"
        echo "         length declarado: $declared"
        echo "         tamaño real:      $actual"
        echo "         Sparkle RECHAZA la actualización. Auto-update roto."
        fails=$((fails + 1))
    else
        echo "  OK     [$os] $(basename "$url") ($actual bytes)"
    fi
done < "$TMP/enclosures.txt"

hist=$(wc -l < "$TMP/historicos.txt" | tr -d ' ')
if [ "$hist" -gt 0 ]; then
    echo "  ($hist items históricos no se comprueban: Sparkle nunca los descarga)"
fi
echo ""

# ── 3. Firmas presentes ─────────────────────────────────────────────────
sigs=$(grep -c 'sparkle:edSignature=' "$APPCAST" || true)
sigs=${sigs:-0}
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
    echo "NO PUBLICAR: $fails de $checked item(s) vivos no casan con el hosting."
    echo "El auto-update está roto AHORA MISMO para esa plataforma."
    exit 1
fi
echo "PUBLICABLE: los $checked item(s) vivos casan con el hosting."
if [ "$live_dupes" -gt 0 ]; then
    echo ""
    echo "AVISO: $live_dupes item(s) VIVO(s) cuelgan de un alias mutable. En cuanto"
    echo "subas la version nueva con ese mismo nombre, el item pasara a declarar un"
    echo "tamano que ya no existe y el auto-update se rompera en silencio. Apunta el"
    echo "<enclosure> a la URL VERSIONADA de GitHub Releases:"
    echo "  https://github.com/TioKino/djanalyzerpro-web/releases/download/<tag>/DJAnalyzerPro-<ver>.dmg"
elif [ "$dupes" -gt 0 ]; then
    echo ""
    echo "(Los avisos de URLs duplicadas de arriba son de items HISTORICOS, que se"
    echo " quedan en el alias a proposito. Los vivos ya apuntan a URLs versionadas"
    echo " e inmutables, que es como debe ser desde la 2.9.8.)"
fi
