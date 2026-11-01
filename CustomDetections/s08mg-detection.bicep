// CustomDetection (Microsoft Defender XDR) at MANAGEMENT-GROUP scope via the MicrosoftSecurity Bicep extension.
// Same content as the graph scenario but targetScope='managementGroup' so
// `az deployment mg create` / `New-AzManagementGroupDeployment` matches.
targetScope = 'managementGroup'
extension MicrosoftSecurity

@description('Branch prefix - keeps id/title unique across branches in a shared tenant.')
param prefix string = 's08mg'

resource detectionRule 'Microsoft.Security/detectionRules@2026-06-01-preview' = {
  id: '${prefix}-detrule-01'
  displayName: '${prefix} cac-test detection 01'
  status: 'enabled'
  queryCondition: {
    queryText: 'DeviceProcessEvents | where FileName =~ "certutil.exe" | project DeviceId, Timestamp, FileName'
  }
  schedule: {
    frequency: 'PT1H'
  }
  detectionAction: {
    alertTemplate: {
      title: '${prefix} cac-test detection 01'
      description: 'cac-test ${prefix} custom detection'
      severity: 'medium'
      tactics: [
        {
          tactic: 'Execution'
          techniques: [
            {
              technique: 'T1059'
            }
          ]
        }
      ]
      entityMappings: {
        hosts: [
          {
            id: 'h'
            deviceIdColumn: 'DeviceId'
          }
        ]
      }
    }
  }
}
