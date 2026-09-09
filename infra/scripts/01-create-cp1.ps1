# Cria a VM control-plane (k8s-cp1) no VMware Workstation e inicia a instalacao
# desatendida a partir do ISO com kickstart. Nao requer interacao.
$ErrorActionPreference = 'Stop'

$LAB    = 'C:\k8s-lab'
$VMDIR  = "$LAB\k8s-cp1"
$VMX    = "$VMDIR\k8s-cp1.vmx"
$ISO    = "$LAB\rocky9-ks.iso"
$VMWARE = 'C:\Program Files (x86)\VMware\VMware Workstation'
$VDISK  = "$VMWARE\vmware-vdiskmanager.exe"
$VMRUN  = "$VMWARE\vmrun.exe"

if (-not (Test-Path $ISO)) { throw "ISO de kickstart nao encontrado: $ISO. Rode build-ks-iso.sh antes." }

# --- Recria o diretorio da VM ---
if (Test-Path $VMDIR) {
    $ErrorActionPreference = 'SilentlyContinue'
    & $VMRUN stop $VMX hard | Out-Null
    $ErrorActionPreference = 'Stop'
    Start-Sleep -Seconds 2
    Remove-Item $VMDIR -Recurse -Force
}
New-Item -ItemType Directory $VMDIR | Out-Null

# --- Disco virtual 20GB, dinamico, arquivo unico ---
Write-Host "==> Criando disco de 20GB..."
& $VDISK -c -s 20GB -a lsilogic -t 0 "$VMDIR\k8s-cp1.vmdk" | Out-Null

# --- VMX ---
# MAC fixo => reserva DHCP estavel (o IP nunca muda entre reboots)
$MAC = '00:50:56:2A:10:11'
# VMX exige barras duplas no caminho do ISO
$isoVmx = $ISO.Replace('\', '\\')

$vmxBody = @"
.encoding = "windows-1252"
config.version = "8"
virtualHW.version = "19"
displayName = "k8s-cp1"
guestOS = "centos9-64"

numvcpus = "2"
cpuid.coresPerSocket = "2"
memsize = "3072"

pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"

scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "k8s-cp1.vmdk"

sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$isoVmx"
sata0:0.startConnected = "TRUE"
sata0:0.allowGuestConnectionControl = "FALSE"

ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "vmxnet3"
ethernet0.addressType = "static"
ethernet0.address = "$MAC"
ethernet0.startConnected = "TRUE"
ethernet0.wakeOnPcktRcv = "FALSE"

firmware = "bios"
vmci0.present = "TRUE"
tools.syncTime = "TRUE"
tools.upgrade.policy = "manual"
# msg.autoAnswer nao pode ficar TRUE: ao menor aviso sobre o CD, o auto-answer
# aceita o default (desconectar) e o instalador perde a midia (capacity=0).
msg.autoAnswer = "FALSE"
gui.exitOnCLIHLT = "FALSE"
floppy0.present = "FALSE"
sound.present = "FALSE"
usb.present = "FALSE"

# Nested virt desligado: containerd nao precisa
vhv.enable = "FALSE"
"@

# nvram/vmxf guardam o mapeamento PCI antigo e causam "No PCIe slot available"
Remove-Item "$VMDIR\nvram","$VMDIR\*.vmxf","$VMDIR\*.scoreboard" -Force -ErrorAction SilentlyContinue

$vmxPath = [System.IO.Path]::GetFullPath($VMX)
[System.IO.File]::WriteAllText($vmxPath, $vmxBody, [System.Text.Encoding]::ASCII)
Write-Host "==> VMX criado: $VMX"

# --- Sobe a VM (headless para nao roubar foco; use 'gui' se quiser ver) ---
Write-Host "==> Iniciando instalacao desatendida (10-15 min)..."
& $VMRUN -T ws start $VMX nogui
Write-Host "==> VM iniciada. Acompanhe com: vmrun list"
Write-Host "    MAC=$MAC  -> IP esperado 192.168.172.11 (apos reserva DHCP)"
