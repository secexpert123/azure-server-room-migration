// main.bicep
// Azure environment for a small company moving off an on-prem server room:
// file share, web app + SQL, finance VM, backup, alerts, budget and tags.
// Policies and role assignments are off by default (deployPolicies, deployRoles)
// because they need Owner on the resource group.

targetScope = 'resourceGroup'

// ---------- Parameters ----------
@allowed([ 'dev', 'prod' ])
param env string = 'dev'
param prefix string = 'vindo'
param location string = 'swedencentral'
param owner string
param adminUsername string = 'vindoadmin'
@secure()
param adminPassword string
@description('Your public IP, without /32')
param rdpSourceIp string
@description('Allow (true) or Deny (false) RDP from your IP')
param rdpEnabled bool = true
param alertEmail string
param budgetAmount int = 250
param budgetMonth string = utcNow('yyyy-MM')
@description('Use only if your subscription supports the Azure SQL free offer')
param useSqlFreeOffer bool = false
@description('Set e.g. Standard_B2ms if your quota blocks the default size')
param vmSizeOverride string = ''
@description('Needs Owner/Resource Policy Contributor on the resource group')
param deployPolicies bool = false
@description('Needs Owner/User Access Administrator on the resource group')
param deployRoles bool = false
@description('Entra group object IDs (leave empty to skip that assignment)')
param grpIt string = ''
param grpLedning string = ''
param grpEkonomi string = ''
param grpProjekt string = ''
param grpInkop string = ''
@description('Adds managed identity + Entra login extension to the VM')
param enableEntraLogin bool = false

// ---------- Variables ----------
var isProd = env == 'prod'
var sfx = 'swec-01'
var uniq = take(uniqueString(resourceGroup().id), 5)

// Tags per department so Finance can see IT cost per department
var baseTags = {
  owner: owner
  env: env
}
var tagsIt = union(baseTags, { avdelning: 'IT' })
var tagsEkonomi = union(baseTags, { avdelning: 'Ekonomi' })
var tagsProjekt = union(baseTags, { avdelning: 'Projekt' })

var vmSize = !empty(vmSizeOverride) ? vmSizeOverride : (isProd ? 'Standard_B2ls_v2' : 'Standard_B2s')
var diskType = isProd ? 'StandardSSD_LRS' : 'Standard_LRS'
var planSku = isProd ? { name: 'B1', tier: 'Basic' } : { name: 'F1', tier: 'Free' }
var shareTier = isProd ? 'Cool' : 'TransactionOptimized'
var shareQuota = isProd ? 2048 : 5

// Built-in role definition IDs
var roleContributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var roleCostMgmtReader = '72fafb9e-0641-4937-9268-a91bfd8191a3'
var roleSmbContributor = '0c867c2a-1d8c-454a-a3db-ab2ea1bdfc22'
var roleSmbReader = 'aba4ae5f-2193-4029-9191-0cb91df5e314'
var roleVmUserLogin = 'fb879df8-f326-4884-b1cf-06f3ad86be52'

// ---------- Storage and Azure Files (Projekt) ----------
resource st 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'st${prefix}${env}${uniq}'
  location: location
  tags: tagsProjekt
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource fileSvc 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: st
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
  }
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileSvc
  name: 'ritningar'
  properties: {
    accessTier: shareTier
    shareQuota: shareQuota
    enabledProtocols: 'SMB'
  }
}

// ---------- Project portal (Projekt) ----------
resource plan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: 'asp-${prefix}-portal-${env}-${sfx}'
  location: location
  tags: tagsProjekt
  sku: planSku
}

resource web 'Microsoft.Web/sites@2022-09-01' = {
  name: 'app-${prefix}-portal-${env}-${sfx}-${uniq}'
  location: location
  tags: tagsProjekt
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
    }
  }
}

resource sql 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: 'sql-${prefix}-portal-${env}-${sfx}-${uniq}'
  location: location
  tags: tagsProjekt
  properties: {
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    minimalTlsVersion: '1.2'
  }
}

resource sqlAzureAccess 'Microsoft.Sql/servers/firewallRules@2022-05-01-preview' = {
  parent: sql
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource db 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sql
  name: 'sqldb-${prefix}-portal-${env}-${sfx}'
  location: location
  tags: tagsProjekt
  sku: {
    name: 'GP_S_Gen5_1'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
    maxSizeBytes: useSqlFreeOffer ? 34359738368 : 2147483648
    useFreeLimit: useSqlFreeOffer
    freeLimitExhaustionBehavior: useSqlFreeOffer ? 'AutoPause' : null
  }
}

// ---------- Network (Ekonomi) ----------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'nsg-ekonomi-${env}-${sfx}'
  location: location
  tags: tagsEkonomi
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP-from-admin'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: rdpEnabled ? 'Allow' : 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: '${rdpSourceIp}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: 'vnet-${prefix}-${env}-${sfx}'
  location: location
  tags: tagsIt
  properties: {
    addressSpace: { addressPrefixes: [ '10.0.0.0/16' ] }
    subnets: [
      {
        name: 'snet-ekonomi'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: 'pip-ekonomi-${env}-${sfx}'
  location: location
  tags: tagsEkonomi
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: 'nic-ekonomi-${env}-${sfx}'
  location: location
  tags: tagsEkonomi
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: vnet.properties.subnets[0].id }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

// ---------- Finance VM (Ekonomi) ----------
resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: 'vm-ekonomi-${env}-${sfx}'
  location: location
  tags: tagsEkonomi
  identity: enableEntraLogin ? { type: 'SystemAssigned' } : null
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'vmekonomi01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        patchSettings: { patchMode: 'AutomaticByOS' }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: diskType }
      }
    }
    networkProfile: { networkInterfaces: [ { id: nic.id } ] }
  }
}

resource entraLogin 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = if (enableEntraLogin) {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  tags: tagsEkonomi
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
}

resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vm.name}'
  location: location
  tags: tagsEkonomi
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: '1900' }
    timeZoneId: 'W. Europe Standard Time'
    notificationSettings: { status: 'Disabled' }
    targetResourceId: vm.id
  }
}

// ---------- Backup (IT) - daily 18:00 Stockholm time, before the 19:00 shutdown ----------
resource vault 'Microsoft.RecoveryServices/vaults@2023-04-01' = {
  name: 'rsv-${prefix}-${env}-${sfx}'
  location: location
  tags: tagsIt
  sku: { name: 'RS0', tier: 'Standard' }
  properties: {
    publicNetworkAccess: 'Enabled'
    securitySettings: {
      immutabilitySettings: { state: 'Unlocked' }
      softDeleteSettings: {
        softDeleteState: 'Enabled'
        softDeleteRetentionPeriodInDays: 14
      }
    }
  }
}

resource vaultCfg 'Microsoft.RecoveryServices/vaults/backupstorageconfig@2023-04-01' = {
  parent: vault
  name: 'vaultstorageconfig'
  properties: {
    storageModelType: 'LocallyRedundant'
    crossRegionRestoreFlag: false
  }
}

resource bkPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-04-01' = {
  parent: vault
  name: 'pol-vm-daily-14d'
  properties: {
    backupManagementType: 'AzureIaasVM'
    instantRpRetentionRangeInDays: 2
    timeZone: 'W. Europe Standard Time'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [ '2026-01-01T18:00:00Z' ]
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [ '2026-01-01T18:00:00Z' ]
        retentionDuration: {
          count: 14
          durationType: 'Days'
        }
      }
    }
  }
}

var containerName = 'iaasvmcontainer;iaasvmcontainerv2;${resourceGroup().name};${vm.name}'
var itemName = 'vm;iaasvmcontainerv2;${resourceGroup().name};${vm.name}'

resource protectedVm 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2023-04-01' = {
  name: '${vault.name}/Azure/${containerName}/${itemName}'
  location: location
  properties: {
    protectedItemType: 'Microsoft.Compute/virtualMachines'
    policyId: bkPolicy.id
    sourceResourceId: vm.id
  }
  // Storage redundancy must be set before the first item is protected
  dependsOn: [ vaultCfg ]
}

// ---------- Monitoring (IT) ----------
resource ag 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${prefix}-ops-${env}'
  location: 'global'
  tags: tagsIt
  properties: {
    groupShortName: 'vindoops'
    enabled: true
    emailReceivers: [
      {
        name: 'it-lead'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${prefix}-ekonomi-cpu-${env}'
  location: 'global'
  tags: tagsIt
  properties: {
    description: 'CPU above 85% for 15 minutes'
    severity: 2
    enabled: true
    scopes: [ vm.id ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighCPU'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          threshold: 85
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [ { actionGroupId: ag.id } ]
  }
}

// ---------- Budget ----------
resource budget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: 'bgt-${prefix}-${env}-${budgetAmount}'
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: { startDate: '${budgetMonth}-01T00:00:00Z' }
    notifications: {
      actual50: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [ alertEmail ]
      }
      actual80: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: [ alertEmail ]
      }
      forecast100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: [ alertEmail ]
      }
    }
  }
}

// ---------- RBAC (second pass: -p deployRoles=true grp...=<object ids>) ----------
resource raIt 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoles && !empty(grpIt)) {
  name: guid(resourceGroup().id, 'it-admins', grpIt, roleContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleContributor)
    principalId: grpIt
    principalType: 'Group'
  }
}

resource raLedning 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoles && !empty(grpLedning)) {
  name: guid(resourceGroup().id, 'ledning', grpLedning, roleCostMgmtReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCostMgmtReader)
    principalId: grpLedning
    principalType: 'Group'
  }
}

resource raEkonomi 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoles && !empty(grpEkonomi)) {
  name: guid(resourceGroup().id, 'ekonomi', grpEkonomi, roleVmUserLogin)
  scope: vm
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleVmUserLogin)
    principalId: grpEkonomi
    principalType: 'Group'
  }
}

resource raProjekt 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoles && !empty(grpProjekt)) {
  name: guid(resourceGroup().id, 'projekt', grpProjekt, roleSmbContributor)
  scope: share
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSmbContributor)
    principalId: grpProjekt
    principalType: 'Group'
  }
}

resource raInkop 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoles && !empty(grpInkop)) {
  name: guid(resourceGroup().id, 'inkop', grpInkop, roleSmbReader)
  scope: share
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSmbReader)
    principalId: grpInkop
    principalType: 'Group'
  }
}

// ---------- Policies (second pass: -p deployPolicies=true) ----------
var requiredTags = [ 'owner', 'env', 'avdelning' ]

resource polLocation 'Microsoft.Authorization/policyAssignments@2022-06-01' = if (deployPolicies) {
  name: 'pa-allowed-locations'
  properties: {
    displayName: 'Allowed locations (EU only)'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')
    parameters: {
      listOfAllowedLocations: { value: [ 'swedencentral', 'westeurope' ] }
    }
  }
}

resource polTags 'Microsoft.Authorization/policyAssignments@2022-06-01' = [for t in requiredTags: if (deployPolicies) {
  name: 'pa-require-tag-${t}'
  properties: {
    displayName: 'Require tag ${t}'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', '871b6d14-10aa-478d-b590-94f262ecfa99')
    parameters: {
      tagName: { value: t }
    }
  }
}]

output webHost string = web.properties.defaultHostName
output storageName string = st.name
output vmName string = vm.name
output nsgName string = nsg.name
