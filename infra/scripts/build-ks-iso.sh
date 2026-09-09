#!/usr/bin/env bash
# Gera um ISO derivado do Rocky 9 minimal com kickstart embutido.
# Roda dentro do WSL. Saida: C:\k8s-lab\rocky9-ks.iso
set -euo pipefail

LAB=/mnt/c/k8s-lab
SRC="$LAB/Rocky-9-latest-x86_64-minimal.iso"
OUT="$LAB/rocky9-ks.iso"
KS="/mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/infra/cloud-init/ks.cfg"
WORK=/tmp/ksbuild

[ -f "$SRC" ] || { echo "ERRO: ISO de origem nao encontrado em $SRC"; exit 1; }
[ -f "$KS" ]  || { echo "ERRO: ks.cfg nao encontrado em $KS"; exit 1; }

echo "==> Limpando area de trabalho"
rm -rf "$WORK"; mkdir -p "$WORK/iso"

echo "==> Extraindo ISO original (pode levar 1-2 min)"
xorriso -osirrox on -indev "$SRC" -extract / "$WORK/iso" 2>/dev/null
chmod -R u+w "$WORK/iso"

echo "==> Descobrindo o LABEL do volume (necessario para inst.stage2)"
LABEL=$(blkid -o value -s LABEL "$SRC" 2>/dev/null || true)
if [ -z "$LABEL" ]; then
  LABEL=$(xorriso -indev "$SRC" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: *//p' | head -1)
fi
[ -n "$LABEL" ] || { echo "ERRO: nao consegui ler o LABEL do ISO"; exit 1; }
# Escapa espacos no formato que o kernel espera (\x20)
ESCAPED=$(printf '%s' "$LABEL" | sed 's/ /\\x20/g')
echo "    LABEL='$LABEL'  ->  '$ESCAPED'"

echo "==> Injetando ks.cfg"
cp "$KS" "$WORK/iso/ks.cfg"

# Parametros de boot: carrega o ks.cfg do proprio CD, sem interacao
APPEND="inst.stage2=hd:LABEL=${ESCAPED} inst.ks=cdrom:/ks.cfg quiet"

echo "==> Reescrevendo bootloader BIOS (isolinux)"
if [ -f "$WORK/iso/isolinux/isolinux.cfg" ]; then
  sed -i "s/^timeout .*/timeout 10/" "$WORK/iso/isolinux/isolinux.cfg"
  sed -i "s|inst.stage2=hd:LABEL=[^ ]*|${APPEND}|g" "$WORK/iso/isolinux/isolinux.cfg"
  sed -i "s/^default .*/default linux/" "$WORK/iso/isolinux/isolinux.cfg"
fi

echo "==> Reescrevendo bootloader UEFI (grub)"
for G in "$WORK/iso/EFI/BOOT/grub.cfg" "$WORK/iso/boot/grub2/grub.cfg"; do
  [ -f "$G" ] || continue
  sed -i "s/^set timeout=.*/set timeout=1/" "$G"
  sed -i "s|inst.stage2=hd:LABEL=[^ ]*|${APPEND}|g" "$G"
  sed -i "s/^set default=.*/set default=\"0\"/" "$G"
done

echo "==> Remasterizando ISO hibrido (BIOS + UEFI)"
rm -f "$OUT"
xorriso -as mkisofs \
  -iso-level 3 -rational-rock -joliet \
  -volid "$LABEL" \
  -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot -e images/efiboot.img -no-emul-boot \
  -isohybrid-gpt-basdat \
  -o "$OUT" "$WORK/iso" 2>&1 | tail -5

echo "==> Pronto: $OUT"
ls -lh "$OUT"
rm -rf "$WORK"
