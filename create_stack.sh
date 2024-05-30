#!/bin/env bash

# Bash script to create a demo AWS MemoryDB using Upbound Creossplane
# The README.md file has more information

# Set some values
REGION="eu-north-1"
PROVIDERREF="provider-aws" # "default" in beta master

NAMESPACE="upbound-resources"
SECRETNAME="memorydb-passwords"
USERNAME="memorydb-usr"
ACLNAME="memorydb-acl"
CLUSTERNAME="memorydb-cluster"
# Used for shared resources: security group, subnet group and parameter group
SHAREDPREFIX="memorydb"
# Delete the AWS resources when the Crossplane resources are
DELETIONPOLICY="Delete"
# Node type; probably other settings that could be added here, but this is most relevant when testing
NODETYPE="db.t4g.small"
# Maintenance window; once every 7 days
MAINTENANCE="fri:02:30-fri:03:30"
# Snapshot window; once every 24 hours. Must not overlap with the maintenance window
SNAPSHOT="03:30-04:30"

# Get some values; if the AWS credentials fail or the default VPC isn't found, bail out
unset VPCID
VPCID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true 2> /dev/null | jq --raw-output '.Vpcs[0].VpcId' )
[ -z "$VPCID" ] && echo "VPC variable not set - are the AWS keys current or is there no default VPC? - bailing out" && exit 0

SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPCID | jq --raw-output '.Subnets[].SubnetId')

# Security group
cat > 1_securitygroup.yaml <<EOF
# The same port (6379) is used for Elasticache and for MemoryDB
# but more self-contained for each to have a dedicated security
# group.
---
apiVersion: ec2.aws.upbound.io/v1beta1
kind: SecurityGroup
metadata:
  name: ${SHAREDPREFIX}-access
  labels:
    selector : ${SHAREDPREFIX}-access-sg
spec:
  forProvider:
    # Change VPC value
    vpcId: ${VPCID}
    name: ${SHAREDPREFIX}-access-sg
    description: Redis access for MemoryDB
    region: ${REGION}
  providerConfigRef:
    name: ${PROVIDERREF}
---
apiVersion: ec2.aws.upbound.io/v1beta1
kind: SecurityGroupRule
metadata:
  name: ${SHAREDPREFIX}-access-sg-rule
spec:
  forProvider:
    description: Redis access for MemoryDB rule
    fromPort: 6379
    toPort: 6379
    protocol: tcp
    type: ingress
    cidrBlocks:
    - 10.0.0.0/8
    - 172.31.0.0/16
    securityGroupIdSelector:
      matchControllerRef: false
      matchLabels:
        selector : ${SHAREDPREFIX}-access-sg
    region: ${REGION}
  providerConfigRef:
    name: ${PROVIDERREF}
EOF

# Generate the manifest file for the subnet group

PART1="apiVersion: memorydb.aws.upbound.io/v1beta1
kind: SubnetGroup
metadata:
  labels:
    selector: ${SHAREDPREFIX}-subnetgroup
  name: ${SHAREDPREFIX}-subnetgroup
spec:
  forProvider:
    description: Subnet group for MemoryDB managed by Crossplane
    region: ${REGION}
    subnetIds:
"

PART2=""
IFS=" "
readarray -t SUBNETARRAY <<< "$SUBNETS"
for (( n=0; n < ${#SUBNETARRAY[*]}; n++))
do
  PART2="$PART2      - ${SUBNETARRAY[n]}\n"
done

PART3="  providerConfigRef:
    name: ${PROVIDERREF}
"

echo -e "$PART1$PART2$PART3" > 2_subnetgroup.yaml

# Generate the manifest file for the parameter group

cat > 3_parametergroup.yaml <<EOF
apiVersion: memorydb.aws.upbound.io/v1beta1
kind: ParameterGroup
metadata:
  labels:
    selector: ${SHAREDPREFIX}-parameter-group
  name: ${SHAREDPREFIX}-parameter-group
spec:
  forProvider:
    description: Parameter group managed by Crossplane
    family: memorydb_redis7
    # A couple of example parameter settings
    parameter:
      - name: maxmemory-policy
        value: allkeys-lru
      - name: active-defrag-cycle-max
        value: "33"
    region: ${REGION}
  providerConfigRef:
    name: ${PROVIDERREF}
EOF

# And that is the manifest files for the prerequisites done

# A Secret with a couple of password values; Redis users can have two of them, perhaps for rotation
# To be provisioned as a Sealed Secret in the Resurs clusters
cat > 4_secret.yaml <<EOF
# Make sure the namespace is provisioned before provisioning the secret
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: user-passwords
  namespace: ${NAMESPACE}
type: Opaque
data:
  password1: dGVzdFBhc3N3b3JkITEyMw== # testPassword!123
  password2: dGVzdFBhc3N3b3JkITEyMw== # testPassword!123
...
EOF

# User; should be provisioned before the ACL

cat > 5_user.yaml <<EOF
apiVersion: memorydb.aws.upbound.io/v1beta1
kind: User
metadata:
  name: ${USERNAME}
spec:
  deletionPolicy: ${DELETIONPOLICY}
  forProvider:
    # Access to all commands through the ACL specified by the cluster which specifies in turn this user
    # The access string itself will likely need to be synched with the application owner/developers
    # The value given here is from the Upbound example code and probably very open
    accessString: on ~* &* +@all
    # Password authentication is the only option for now?
    authenticationMode:
      - passwordsSecretRef:
          - key: password1
            name: user-passwords
            namespace: ${NAMESPACE}
          - key: password2
            name: user-passwords
            namespace: ${NAMESPACE}
        type: password
    region: ${REGION}

  writeConnectionSecretToRef:
    name: conn-${USERNAME}
    namespace: ${NAMESPACE}

  providerConfigRef:
    name: ${PROVIDERREF}
EOF


# Now the ACL

cat > 6_acl.yaml <<EOF
---
apiVersion: memorydb.aws.upbound.io/v1beta1
kind: ACL
metadata:
  labels:
    selector: ${ACLNAME}
  name: ${ACLNAME}
spec:
  deletionPolicy: ${DELETIONPOLICY}
  forProvider:
    region: ${REGION}
    # Assign users to ACL here
    userNames:
      - ${USERNAME}

  # This is documented as a repository for connection details, but no data is stored by the following lines
  # Probably a placeholder that can be used when creating a Composition; ignore it for now
  # writeConnectionSecretToRef:
  #   name: conn-${ACLNAME}
  #   namespace: ${NAMESPACE}

  providerConfigRef:
    name: ${PROVIDERREF}
...
EOF

# And to finish off, the cluster

cat > 7_cluster.yaml <<EOF
# Simple cluster definition, uses the prerequisites created using the manifests generated by the script
# Get the cluster endpoint:
# kubectl get cluster.memorydb.aws.upbound.io/memorydb-cluster -o json | jq -r '.status.atProvider.clusterEndpoint[].address'
apiVersion: memorydb.aws.upbound.io/v1beta1
kind: Cluster
metadata:
  labels:
    selector: memorydb-cluster
  name: memorydb-cluster
spec:
  deletionPolicy: ${DELETIONPOLICY}
  forProvider:
    # Assign users via the ACL
    # One ACL per cluster; multiple users per ACL
    aclName: ${ACLNAME}
    description: Cluster managed by Crossplane
    engineVersion: "7.0"
    # Maintenance window; must not overlap with the snapshot window
    maintenanceWindow: ${MAINTENANCE}
    nodeType: ${NODETYPE}
    numReplicasPerShard: 0
    numShards: 1
    parameterGroupName: ${SHAREDPREFIX}-parameter-group
    port: 6379
    region: ${REGION}
    # Automatic snapshots are taken once daily and retained for the number of days given, max 35
    snapshotRetentionLimit: 7
    # Snapshot window
    snapshotWindow: ${SNAPSHOT}
    securityGroupIdSelector:
      matchLabels:
        selector: ${SHAREDPREFIX}-access-sg
    subnetGroupNameSelector:
      matchLabels:
        selector: ${SHAREDPREFIX}-subnetgroup
  providerConfigRef:
    name: ${PROVIDERREF}
EOF

# Use the built-in 'read' command to handle multiline output
read -r -d '' usage <<-EOF

Run the following commands in the given order:
    kubectl apply -f 1_securitygroup.yaml
    kubectl apply -f 2_subnetgroup.yaml
    kubectl apply -f 3_parametergroup.yaml
    kubectl apply -f 4_secret.yaml
    kubectl apply -f 5_user.yaml
    kubectl apply -f 6_acl.yaml
    kubectl apply -f 7_cluster.yaml

Troubleshooting is easier with separate manifest files so leaving it at that for now
EOF
echo "$usage"

