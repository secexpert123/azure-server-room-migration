# Azure server room migration

A plan and a small working build for moving a fictional construction company, Vindö Bygg AB, from an on-prem server room to Azure. I did this as an individual project in my Cloud & ICT Engineering studies in Stockholm. The plan follows the Microsoft Cloud Adoption Framework.

## The scenario

Vindö Bygg has 85 employees in Uppsala and four departments: Ledning, Ekonomi, Projekt and Inköp. Site managers work on building sites with laptops and tablets on the mobile network. The company wants to close its server room within six months. Management had five wishes:

1. Close the server room within six months.
2. Site managers reach drawings and the project portal securely from site, without a VPN.
3. The CFO can see IT cost per department.
4. Customer data stays in the EU.
5. Better protection against ransomware, and a way to restore data.

## What is in this repo

- `main.bicep`: one template that builds the environment. The `env` parameter switches between dev and prod sizes.
- `entra-groups-and-second-pass.ps1`: creates one Entra security group per department, then redeploys the template with policies and role assignments turned on.

## What I built and tested

I deployed a small dev copy in a resource group on a student subscription, then deleted it after testing. The web app only shows the default Azure start page, and no real application or data was moved.

- Storage account with an Azure Files share, soft delete 14 days, TLS 1.2, no public blob access
- App Service and Azure SQL (serverless, auto-pause) for the project portal
- Windows Server 2022 VM for the finance system, with auto-shutdown at 19:00 and RDP allowed only from my own IP
- Recovery Services vault with a daily VM backup kept for 14 days
- CPU alert with an email action group
- Budget with alerts at 50% and 80% actual cost and 100% forecast
- Tags owner, env and avdelning on every resource, so Cost Management can show cost per department

Results from the tests:

- Backup now and restore of the VM worked. The restore took 2 minutes 16 seconds, well inside my 4 hour recovery target.
- I pushed the CPU above the threshold on purpose. The alert fired and the email arrived.
- Cost analysis grouped by the avdelning tag shows cost per department.

The production estimate from the Azure Pricing Calculator is about SEK 1,443 per month.

One caveat: after the backup test I changed the backup time in the template to 18:00 Stockholm time. I did not deploy that version again.

## What I only described

I only had Contributor on the resource group, so I could not build everything. These parts are written down but were never run:

- Entra groups, Conditional Access and MFA rollout
- Role assignments (RBAC) for the groups
- Azure Policy for allowed regions and required tags

The script and the template parameters for the groups, roles and policies are ready, but they have not been tested. I also tried to create a storage account in East US. It was not blocked, because the school's policy did not enforce the region rule. So the EU-only rule is designed but not proven.

## How to deploy

You need the Azure CLI and a resource group. The template asks for the admin password when it runs, so no password is stored in the code.

```
az deployment group what-if -g <resource-group> -f main.bicep \
  -p owner=<name> alertEmail=<email> rdpSourceIp=<your-ip> vmSizeOverride=Standard_B2ls_v2

az deployment group create -g <resource-group> -f main.bicep \
  -p owner=<name> alertEmail=<email> rdpSourceIp=<your-ip> vmSizeOverride=Standard_B2ls_v2
```

Run what-if first. The template creates a budget, so set the amount with `budgetAmount` if you do not want SEK 250.

A vault that holds backup data cannot be deleted straight away. Stop protection and switch off soft delete first.

## What I would change for production

- Backup vault with GRS and cross region restore, keeping the copy in the EU
- Defender for SQL and an Entra administrator for the SQL server, instead of a SQL password
- Private endpoint for the database
- Trusted Launch and a Premium or Standard SSD OS disk for the finance VM
- Paid App Service plan with two instances and a health check
- Azure Bastion or just-in-time access instead of RDP from an IP address

## Name guide

Some names are Swedish because the company is Swedish.

- avdelning: department
- ritningar: drawings
- Ledning: management
- Ekonomi: finance
- Projekt: projects
- Inköp: purchasing
