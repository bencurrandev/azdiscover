#!/usr/bin/env bash
#
# azdiscover.sh - Discovery report for an Azure environment, written as Markdown.
# Designed for Azure Cloud Shell (Bash). Requires: az CLI (logged in) and jq.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: azdiscover.sh [options]

Runs discovery against the current Azure tenant and writes a Markdown report.

Options:
  -o FILE   Output file (default: ./azdiscover-<timestamp>.md)
  -s SUBID  Limit subscription-level discovery to this subscription ID (repeatable)
  -m MGID   Management group to use as the hierarchy root (default: tenant root group)
  -h        Show this help

Sections:
  1. Management group and subscription hierarchy
  2. Azure Policy assignments (management group, subscription, resource group, resource)
  3. RBAC assignments at management group and subscription scope
  4. Resource groups per subscription with location and direct RBAC assignments
  5. Network resources per subscription (VNets, peerings, private endpoints,
     ExpressRoute circuits/connections, public IPs)
EOF
}

OUT=""
ROOT_MG=""
SUB_FILTER=()

while getopts ":o:s:m:h" opt; do
  case $opt in
    o) OUT="$OPTARG" ;;
    s) SUB_FILTER+=("${OPTARG,,}") ;;
    m) ROOT_MG="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage >&2; exit 1 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage >&2; exit 1 ;;
  esac
done

for cmd in az jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd" >&2; exit 1; }
done

if ! ACCOUNT=$(az account show -o json 2>/dev/null); then
  echo "Not logged in to Azure CLI. Run 'az login' first." >&2
  exit 1
fi

TENANT_ID=$(jq -r '.tenantId' <<<"$ACCOUNT")
RUN_AS=$(jq -r '.user.name' <<<"$ACCOUNT")
ROOT_MG="${ROOT_MG:-$TENANT_ID}"
OUT="${OUT:-azdiscover-$(date +%Y%m%d-%H%M%S).md}"
ERRLOG="${OUT%.md}.errors.log"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
: > "$OUT"
: > "$ERRLOG"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

md() { printf '%s\n' "$@" >> "$OUT"; }

# Run an az command that returns JSON. On failure, log and emit an empty array.
azj() {
  local out
  if out=$(az "$@" --only-show-errors -o json 2>>"$ERRLOG"); then
    if [[ -n "$out" ]]; then printf '%s\n' "$out"; else echo '[]'; fi
  else
    printf 'FAILED: az %s\n' "$*" >> "$ERRLOG"
    echo '[]'
  fi
}

JQ_DEFS='
def esc: if . == null or . == "" then "-" else (tostring | gsub("\\|"; "\\|") | gsub("[\r\n]+"; " ")) end;
def row: "| " + (map(esc) | join(" | ")) + " |";
def lastseg: if . == null then null else (split("/") | last) end;
def subof: if . == null then null else ([capture("/subscriptions/(?<s>[^/]+)"; "i").s] | first) end;
def resname: if . == null then null else (([capture("/providers/[^/]+/(?<t>[^/]+)/(?<n>[^/]+)"; "i") | "\(.n) (\(.t))"] | first) // lastseg) end;
def pname: if (.principalName // "") == "" then .principalId else .principalName end;
'

# table <json-file> <"Col A|Col B"> <jq filter emitting one array per row> [extra jq args...]
table() {
  local file="$1" header="$2" filter="$3" rows h="|" s="|" c
  local -a cols
  shift 3
  if ! rows=$(jq -r "$@" "$JQ_DEFS $filter | row" "$file" 2>>"$ERRLOG"); then
    md "_Failed to render table (see error log)._" ""
    return
  fi
  if [[ -z "$rows" ]]; then
    md "_None found._" ""
    return
  fi
  IFS='|' read -ra cols <<<"$header"
  for c in "${cols[@]}"; do h+=" $c |"; s+=" --- |"; done
  md "$h" "$s" "$rows" ""
}

sub_name() { jq -r --arg id "$1" '.[] | select(.id == $id) | .name' "$WORK/subs.json"; }

# Cache of policy/initiative definition ID (lowercase) -> display name.
init_def_cache() {
  log "Caching built-in policy definition names"
  {
    azj policy definition list --query "[?policyType=='BuiltIn'].{id:id,n:displayName}"
    azj policy set-definition list --query "[?policyType=='BuiltIn'].{id:id,n:displayName}"
  } | jq -s 'add | map({key: (.id | ascii_downcase), value: .n}) | from_entries' > "$WORK/defs.json"
}

# Look up display names for any definitions referenced in <file> that are not cached yet.
resolve_defs() {
  local file="$1" id name
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    name=$(az rest --method get --url "${id}?api-version=2023-04-01" --query properties.displayName \
      -o tsv --only-show-errors 2>>"$ERRLOG") || name=""
    jq --arg k "$id" --arg v "$name" '. + {($k): $v}' "$WORK/defs.json" > "$WORK/defs.tmp" \
      && mv "$WORK/defs.tmp" "$WORK/defs.json"
  done < <(jq -r --slurpfile c "$WORK/defs.json" \
    '.[].policyDefinitionId // empty | ascii_downcase | select($c[0][.] == null)' "$file" | sort -u)
}

POLICY_JQ='
def defname: ((.policyDefinitionId // "") | ascii_downcase) as $k | ($c[0][$k] // "") as $n
  | if $n != "" then $n else (.policyDefinitionId | lastseg) end;
def kind: if ((.policyDefinitionId // "") | test("/policySetDefinitions/"; "i")) then "Initiative" else "Policy" end;
'

RBAC_COLS="Principal|Principal Type|Role|Principal ID"
RBAC_JQ='[.[] | select((.scope // "" | ascii_downcase) == $s)] | sort_by(.roleDefinitionName, pname)
  | .[] | [pname, .principalType, .roleDefinitionName, .principalId]'

# ---------------------------------------------------------------------------
# Subscriptions in scope
# ---------------------------------------------------------------------------

log "Enumerating subscriptions"
azj account list --all > "$WORK/subs_all.json"
jq --arg t "$TENANT_ID" \
  '[.[] | select(.tenantId == $t and .state == "Enabled")] | sort_by(.name | ascii_downcase)' \
  "$WORK/subs_all.json" > "$WORK/subs.json"

if ((${#SUB_FILTER[@]})); then
  jq '[.[] | select((.id | ascii_downcase) | IN($ARGS.positional[]))]' --args "${SUB_FILTER[@]}" \
    < "$WORK/subs.json" > "$WORK/subs.tmp" && mv "$WORK/subs.tmp" "$WORK/subs.json"
fi

mapfile -t SUB_IDS < <(jq -r '.[].id' "$WORK/subs.json")
log "Subscriptions in scope: ${#SUB_IDS[@]}"

# ---------------------------------------------------------------------------
# Report header
# ---------------------------------------------------------------------------

md "# Azure Environment Discovery" "" \
   "| Property | Value |" "| --- | --- |" \
   "| Tenant ID | \`$TENANT_ID\` |" \
   "| Hierarchy root | \`$ROOT_MG\` |" \
   "| Generated | $(date -u '+%Y-%m-%d %H:%M UTC') |" \
   "| Run as | $RUN_AS |" \
   "| Subscriptions in scope | ${#SUB_IDS[@]} |" "" \
   "## Contents" "" \
   "1. [Management Group and Subscription Hierarchy](#management-group-and-subscription-hierarchy)" \
   "2. [Azure Policy Assignments](#azure-policy-assignments)" \
   "3. [RBAC Assignments](#rbac-assignments)" \
   "4. [Resource Groups](#resource-groups)" \
   "5. [Network Resources](#network-resources)" ""

# ---------------------------------------------------------------------------
# 1. Management group and subscription hierarchy
# ---------------------------------------------------------------------------

log "Reading management group hierarchy from $ROOT_MG"
md "## Management Group and Subscription Hierarchy" ""

MGS=()
MG_OK=0
if az account management-group show --name "$ROOT_MG" --expand --recurse --only-show-errors -o json \
    > "$WORK/mgtree.json" 2>>"$ERRLOG"; then
  MG_OK=1
  jq -r '
    def ismg: (.type // "") | test("managementGroups"; "i");
    def indent($d): [range($d)] | map("  ") | join("");
    def node($d):
      indent($d) + "- " + (if ismg then "**\(.displayName)** (`\(.name)`)" else "Subscription: \(.displayName) (`\(.name)`)" end),
      ((.children // []) | sort_by((ismg | not), .displayName) | .[] | node($d + 1));
    node(0)' "$WORK/mgtree.json" >> "$OUT"
  md ""
  mapfile -t MGS < <(jq -r '
    def ismg: (.type // "") | test("managementGroups"; "i");
    def mgs: select(ismg) | "\(.name)\t\(.displayName)", ((.children // [])[] | mgs);
    mgs' "$WORK/mgtree.json")
else
  md "_Unable to read the management group hierarchy from \`$ROOT_MG\` (check Management Group Reader permissions). Management group sections are skipped._" ""
fi

md "### Subscriptions in Scope" ""
table "$WORK/subs.json" "Subscription|Subscription ID|State" '.[] | [.name, .id, .state]'

# ---------------------------------------------------------------------------
# 2. Azure Policy assignments
# ---------------------------------------------------------------------------

md "## Azure Policy Assignments" ""
init_def_cache

if ((MG_OK)); then
  md "### Management Group Assignments" ""
  for line in "${MGS[@]}"; do
    IFS=$'\t' read -r mg_name mg_disp <<<"$line"
    scope="/providers/Microsoft.Management/managementGroups/$mg_name"
    log "Policy assignments: management group $mg_disp"
    azj policy assignment list --scope "$scope" > "$WORK/raw.json"
    jq --arg s "${scope,,}" '[.[] | select((.scope // "" | ascii_downcase) == $s)] | sort_by(.displayName // .name)' \
      "$WORK/raw.json" > "$WORK/pa.json"
    resolve_defs "$WORK/pa.json"
    md "#### $mg_disp (\`$mg_name\`)" ""
    table "$WORK/pa.json" "Assignment|Definition|Type|Enforcement" \
      "$POLICY_JQ"'.[] | [(.displayName // .name), defname, kind, .enforcementMode]' \
      --slurpfile c "$WORK/defs.json"
  done
fi

md "### Subscription Assignments" "" \
   "_Includes assignments made at subscription, resource group and resource scope._" ""
for sub in "${SUB_IDS[@]}"; do
  name=$(sub_name "$sub")
  prefix="/subscriptions/${sub,,}"
  log "Policy assignments: subscription $name"
  azj policy assignment list --subscription "$sub" --disable-scope-strict-match > "$WORK/raw.json"
  jq --arg p "$prefix" \
    '[.[] | select((.scope // "" | ascii_downcase) | startswith($p))] | sort_by((.scope | length), (.displayName // .name))' \
    "$WORK/raw.json" > "$WORK/pa.json"
  resolve_defs "$WORK/pa.json"
  md "#### $name (\`$sub\`)" ""
  table "$WORK/pa.json" "Scope Level|Scope|Assignment|Definition|Type|Enforcement" \
    "$POLICY_JQ"'.[] | (.scope | ascii_downcase) as $s
      | [ (if $s == $p then "Subscription"
           elif ($s | test("^/subscriptions/[^/]+/resourcegroups/[^/]+$")) then "Resource Group"
           else "Resource" end),
          (if $s == $p then null else (.scope | sub("^/subscriptions/[^/]+/"; ""; "i")) end),
          (.displayName // .name), defname, kind, .enforcementMode ]' \
    --slurpfile c "$WORK/defs.json" --arg p "$prefix"
done

# ---------------------------------------------------------------------------
# 3. RBAC assignments (management group and subscription scope)
# ---------------------------------------------------------------------------

md "## RBAC Assignments" "" "_Role assignments made directly at each scope; inherited assignments are excluded._" ""

if ((MG_OK)); then
  md "### Management Groups" ""
  for line in "${MGS[@]}"; do
    IFS=$'\t' read -r mg_name mg_disp <<<"$line"
    scope="/providers/Microsoft.Management/managementGroups/$mg_name"
    log "RBAC: management group $mg_disp"
    azj role assignment list --scope "$scope" > "$WORK/raw.json"
    md "#### $mg_disp (\`$mg_name\`)" ""
    table "$WORK/raw.json" "$RBAC_COLS" "$RBAC_JQ" --arg s "${scope,,}"
  done
fi

md "### Subscriptions" ""
for sub in "${SUB_IDS[@]}"; do
  name=$(sub_name "$sub")
  log "RBAC: subscription $name"
  # Retrieved once per subscription; reused for resource group assignments in section 4.
  azj role assignment list --subscription "$sub" --all > "$WORK/ra_$sub.json"
  md "#### $name (\`$sub\`)" ""
  table "$WORK/ra_$sub.json" "$RBAC_COLS" "$RBAC_JQ" --arg s "/subscriptions/${sub,,}"
done

# ---------------------------------------------------------------------------
# 4. Resource groups
# ---------------------------------------------------------------------------

md "## Resource Groups" "" "_RBAC column lists role assignments made directly on the resource group (not inherited)._" ""
for sub in "${SUB_IDS[@]}"; do
  name=$(sub_name "$sub")
  log "Resource groups: subscription $name"
  azj group list --subscription "$sub" > "$WORK/rgs.json"
  md "### $name (\`$sub\`)" ""
  table "$WORK/rgs.json" "Resource Group|Location|Direct RBAC Assignments" \
    'sort_by(.name | ascii_downcase) | .[] | (.id | ascii_downcase) as $id
      | [ .name, .location,
          ([ $ra[0][] | select((.scope // "" | ascii_downcase) == $id)
             | "\(.roleDefinitionName) - \(pname) (\(.principalType))" ] | join("<br>")) ]' \
    --slurpfile ra "$WORK/ra_$sub.json"
done

# ---------------------------------------------------------------------------
# 5. Network resources
# ---------------------------------------------------------------------------

md "## Network Resources" ""
SUBMAP_JQ='($subs[0] | map({key: (.id | ascii_downcase), value: .name}) | from_entries) as $sm | '

for sub in "${SUB_IDS[@]}"; do
  name=$(sub_name "$sub")
  log "Network resources: subscription $name"
  md "### $name (\`$sub\`)" ""

  azj network vnet list --subscription "$sub" > "$WORK/vnets.json"
  md "#### Virtual Networks" ""
  table "$WORK/vnets.json" "VNet|Resource Group|Location|Address Space|Subnets|DNS Servers" \
    'sort_by(.name) | .[] | [ .name, .resourceGroup, .location,
        ((.addressSpace.addressPrefixes // []) | join(", ")),
        ((.subnets // []) | length),
        ((.dhcpOptions.dnsServers // []) | if length == 0 then "Azure-provided" else join(", ") end) ]'

  md "#### VNet Peerings" ""
  table "$WORK/vnets.json" "VNet|Peering|Remote VNet|Remote Subscription|State|Sync|Forwarded Traffic|Gateway Transit|Use Remote Gateways" \
    "$SUBMAP_JQ"'sort_by(.name) | .[] | .name as $v | (.virtualNetworkPeerings // [])[]
      | (.remoteVirtualNetwork.id | subof) as $rs
      | [ $v, .name, (.remoteVirtualNetwork.id | lastseg),
          (if $rs then ($sm[$rs | ascii_downcase] // $rs) else null end),
          .peeringState, .peeringSyncLevel, .allowForwardedTraffic, .allowGatewayTransit, .useRemoteGateways ]' \
    --slurpfile subs "$WORK/subs_all.json"

  azj network private-endpoint list --subscription "$sub" > "$WORK/pe.json"
  md "#### Private Endpoints" ""
  table "$WORK/pe.json" "Private Endpoint|Resource Group|Location|VNet/Subnet|Target Resource|Sub-resource|Status|Private IPs" \
    'sort_by(.name) | .[]
      | (((.privateLinkServiceConnections // []) + (.manualPrivateLinkServiceConnections // []))[0]) as $c
      | [ .name, .resourceGroup, .location,
          ((.subnet.id // "") | [capture("virtualNetworks/(?<v>[^/]+)/subnets/(?<s>[^/]+)"; "i") | "\(.v)/\(.s)"] | first),
          ($c.privateLinkServiceId | resname),
          (($c.groupIds // []) | join(", ")),
          $c.privateLinkServiceConnectionState.status,
          ([(.customDnsConfigs // [])[] | (.ipAddresses // [])[]] | unique | join(", ")) ]'

  azj network express-route list --subscription "$sub" > "$WORK/erc.json"
  md "#### ExpressRoute Circuits" ""
  table "$WORK/erc.json" "Circuit|Resource Group|Location|Provider|Peering Location|Bandwidth|SKU|Circuit State|Provider State" \
    'sort_by(.name) | .[] | [ .name, .resourceGroup, .location,
        (.serviceProviderProperties.serviceProviderName // "ExpressRoute Direct"),
        (.serviceProviderProperties.peeringLocation // null),
        (if .bandwidthInGbps then "\(.bandwidthInGbps) Gbps"
         elif .serviceProviderProperties.bandwidthInMbps then "\(.serviceProviderProperties.bandwidthInMbps) Mbps"
         else null end),
        "\(.sku.tier // "-") / \(.sku.family // "-")",
        .circuitProvisioningState, .serviceProviderProvisioningState ]'

  # Connections have no subscription-wide list API, so enumerate IDs and fetch them in one call.
  mapfile -t conn_ids < <(az resource list --subscription "$sub" --resource-type Microsoft.Network/connections \
    --query "[].id" -o tsv --only-show-errors 2>>"$ERRLOG")
  if ((${#conn_ids[@]})); then
    azj network vpn-connection show --ids "${conn_ids[@]}" | jq 'if type == "array" then . else [.] end' > "$WORK/conns.json"
  else
    echo '[]' > "$WORK/conns.json"
  fi
  md "#### ExpressRoute Connections (VNet Gateway)" ""
  table "$WORK/conns.json" "Connection|Resource Group|Location|VNet Gateway|Circuit|Circuit Subscription|Routing Weight|FastPath|State" \
    "$SUBMAP_JQ"'[.[] | select(.connectionType == "ExpressRoute")] | sort_by(.name) | .[]
      | (.peer.id | subof) as $cs
      | [ .name, .resourceGroup, .location,
          (.virtualNetworkGateway1.id | lastseg),
          (.peer.id | lastseg),
          (if $cs then ($sm[$cs | ascii_downcase] // $cs) else null end),
          .routingWeight, .expressRouteGatewayBypass, .provisioningState ]' \
    --slurpfile subs "$WORK/subs_all.json"

  azj network express-route gateway list --subscription "$sub" > "$WORK/ergw.json"
  md "#### ExpressRoute Connections (Virtual WAN)" ""
  table "$WORK/ergw.json" "ER Gateway|Resource Group|Location|Virtual Hub|Connection|Circuit|Routing Weight|State" \
    'sort_by(.name) | .[] | .name as $g | .resourceGroup as $rg | .location as $l | (.virtualHub.id | lastseg) as $h
      | (.expressRouteConnections // [])[]
      | [ $g, $rg, $l, $h, .name,
          ((.expressRouteCircuitPeering.id // "") | [capture("expressRouteCircuits/(?<c>[^/]+)"; "i").c] | first),
          .routingWeight, .provisioningState ]'

  azj network public-ip list --subscription "$sub" > "$WORK/pip.json"
  md "#### Public IP Addresses" ""
  table "$WORK/pip.json" "Public IP|Resource Group|Location|IP Address|Version|SKU|Allocation|Associated To" \
    'sort_by(.name) | .[] | [ .name, .resourceGroup, .location, .ipAddress, .publicIPAddressVersion,
        .sku.name, .publicIPAllocationMethod, ((.ipConfiguration.id // .natGateway.id) | resname) ]'
done

# ---------------------------------------------------------------------------
# Finish
# ---------------------------------------------------------------------------

if [[ -s "$ERRLOG" ]]; then
  md "---" "" "_Some queries returned errors (often due to missing permissions). See \`$(basename "$ERRLOG")\`._"
  log "Completed with errors - see $ERRLOG"
else
  rm -f "$ERRLOG"
fi

log "Report written to $OUT"
