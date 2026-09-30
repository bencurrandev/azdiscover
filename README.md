# azdiscover

A Bash script for Azure Cloud Shell that runs discovery against an Azure tenant and produces a Markdown report.

## What it reports

1. **Management Group and Subscription hierarchy**: a nested tree from the tenant root (or a chosen management group), plus a table of the subscriptions it covers.
2. **Azure Policy assignments**: grouped by management group and subscription. Subscription tables include assignments made at resource group and resource scope. Each row shows the definition or initiative name and the enforcement mode.
3. **RBAC assignments**: role assignments made directly at management group and subscription scope. Inherited assignments are excluded.
4. **Resource Groups**: for each subscription, the resource groups with their location and any role assignments made directly on the group.
5. **Network resources**: for each subscription:
   - Virtual networks (address space, subnet count, DNS servers)
   - VNet peerings (remote VNet and subscription, state, gateway settings)
   - Private endpoints (subnet, target resource, sub-resource, status, IPs)
   - ExpressRoute circuits
   - ExpressRoute connections (VNet gateway and Virtual WAN)
   - Public IP addresses and the resources they're attached to

## Requirements

- Azure Cloud Shell (Bash), or any Bash environment with:
  - [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), signed in with `az login`
  - [jq](https://jqlang.github.io/jq/)
- Permissions:
  - **Reader** on the root management group (or the management group passed with `-m`) for full coverage
  - Access to read role assignments and policy assignments at the scopes you want reported

If the script can't read the management group hierarchy, it skips the management group sections and still reports on the subscriptions you can access.

## Getting started in Cloud Shell

```bash
git clone https://github.com/bencurrandev/azdiscover.git
cd azdiscover
chmod +x azdiscover.sh
./azdiscover.sh
```

To keep reports between Cloud Shell sessions, write them to `~/clouddrive`:

```bash
./azdiscover.sh -o ~/clouddrive/azdiscover-report.md
```

## Usage

```text
./azdiscover.sh [options]

  -o FILE   Output file (default: ./azdiscover-<timestamp>.md)
  -s SUBID  Limit subscription-level discovery to this subscription ID (repeatable)
  -m MGID   Management group to use as the hierarchy root (default: tenant root group)
  -h        Show help
```

### Examples

```bash
# Entire tenant
./azdiscover.sh

# Specific subscriptions only
./azdiscover.sh -s 00000000-0000-0000-0000-000000000000 -s 11111111-1111-1111-1111-111111111111

# Start the hierarchy at a specific management group
./azdiscover.sh -m platform -o platform-report.md
```

## Output

- `<output>.md`: the report. It renders on GitHub and Azure DevOps, and in VS Code's Markdown preview.
- `<output>.errors.log`: created only if some queries failed, usually because of missing permissions. The report ends with a note pointing to this log.

To download the report from Cloud Shell, use **Manage files > Download** and enter the file path, or run:

```bash
download azdiscover-<timestamp>.md
```

## Notes

- The script only reads from Azure and never changes any resources.
- Only enabled subscriptions in the signed-in tenant are included.
- Large tenants can take a while because the script makes several Azure CLI calls per management group and per subscription. Progress is printed to the terminal.
- `.gitattributes` keeps `*.sh` files at LF line endings, so the script still runs in Cloud Shell when it's committed from Windows.
