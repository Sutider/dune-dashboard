#!/bin/bash

BG_NAME="sh-b17a5f036d1f7882-bzhczd"
NAMESPACE="funcom-seabass-sh-b17a5f036d1f7882-bzhczd"

echo "Patching battlegroup: $BG_NAME"

sudo kubectl patch battlegroup "$BG_NAME" -n "$NAMESPACE" --type=merge -p '{
  "spec": {
    "serverGroup": {
      "template": {
        "spec": {
          "sets": [
            {
              "map": "DeepDesert_1",
              "partitions": [8, 30],
              "replicas": 2,
              "resources": {
                "limits": {
                  "memory": "15Gi"
                }
              },
              "arguments": [
                "-FarmRegion=North America Test",
                "-RMQGameTlsEnabled=true"
              ]
            }
          ]
        }
      }
    }
  }
}'

if [ $? -eq 0 ]; then
    echo "Patch applied successfully"
else
    echo "Failed to apply patch"
    exit 1
fi