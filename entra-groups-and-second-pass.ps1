# entra-groups-and-second-pass.ps1
# Creates one Entra security group per department, then redeploys main.bicep
# with policies and role assignments turned on.
# Needs rights in Entra ID and Owner (or User Access Administrator) on the resource group.
# Replace the <placeholders> before running.

foreach ($g in 'it-admins','ledning','ekonomi','projekt','inkop') {
  az ad group create --display-name "sg-vindo-$g" --mail-nickname "sg-vindo-$g" --description "Vindo Bygg $g"
}

$it  = az ad group show --group sg-vindo-it-admins --query id -o tsv
$led = az ad group show --group sg-vindo-ledning --query id -o tsv
$eko = az ad group show --group sg-vindo-ekonomi --query id -o tsv
$prj = az ad group show --group sg-vindo-projekt --query id -o tsv
$ink = az ad group show --group sg-vindo-inkop --query id -o tsv

# Second pass: policies and role assignments (needs Owner or User Access Administrator on the RG)
# Use the same values as in the first deployment (RDP IP, VM size, adminPassword). rdpEnabled=false keeps the RDP rule closed.
az deployment group create -g <RG> -f main.bicep -p owner=YourName alertEmail=you@domain.com rdpSourceIp=<YOUR-IP> vmSizeOverride=Standard_B2ls_v2 rdpEnabled=false deployPolicies=true deployRoles=true grpIt=$it grpLedning=$led grpEkonomi=$eko grpProjekt=$prj grpInkop=$ink

