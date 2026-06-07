# Este script verifica el cumplimiento post-remediación
$firewall = Get-NetFirewallProfile | Where-Object {$_.Enabled -eq 'True'}
if ($firewall.Count -eq 3) {
    Write-Output "COMPLIANCE: PASSED"
} else {
    Write-Error "COMPLIANCE: FAILED"
    exit 1
}
