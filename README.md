# Crossplane and MemoryDB

**MemoryDB** is AWS' own variant of **Redis** optimised for use as a database (**Elasticache** is for caching). Up until relatively recently Crossplane did not support the full MemoryDB stack, but that has now been fixed. It is still a little rough around the edges, but nothing that can't be managed easily.

AWS' own FAQ for MemoryDB, including a short discussion on differences with Elasticache can be found [here](https://aws.amazon.com/memorydb/faqs/)

The user management described here is AWS' version of the built-in Redis user management, which is likely to be what is currently used on premises. IAM-based user management is also available and could be worth investigating in the future if time becomes available.

### AWS account, EKS and Crossplane

Access to an AWS account with an EKS cluster where the appropriate Crossplane providers ([EC2](https://marketplace.upbound.io/providers/upbound/provider-aws-ec2) and [MemoryDB](https://marketplace.upbound.io/providers/upbound/provider-aws-memorydb/)) have been installed is required.

The script searches for the `default` VPC in the specified AWS Region and uses that plus its subnets for various components, so if for any reason there is no default VPC the script will return an error message instead of generating manifests.

### Demo stack

This stack was was developed and verified using AWS EKS running Kubernetes 1.29, Upbound Crossplane AWS providers v1.4.0 on a laptop running Ubuntu 24.04. The bash version was 5.2.21.

Manifests for the demo stack are created using the bash script `create_stack.sh`, using the currently active AWS credentials. These manifests can then be deployed to provision the demo stack.

In addition to the AWS cli client, the script uses the `jq` JSON processer to deal with output from the AWS client so that needs to be installed.

Various values in the beginning of the script, such as AWS Region, need to be updated (or at least checked). The script checks for access to an AWS account and bails out if it fails, but no check for Crossplane components is done as these are not needed by the script.

Manifests for the following are created:

1. AWS Security group + access rule
2. MemoryDB subnet group
3. MemoryDB parameter group
4. Kubernetes Secret with password for user
5. MemoryDB user account
6. MemoryDB ACL (access control list), which links user accounts to clusters
7. MemoryDB cluster

Manifests 1 - 4 are pretty straight forward; (1) is handled by the Crossplane **EC2** provider, (4) is standard Kubernetes and will likely be provisioned as a **Sealed Secret** outside of the lab, while the two other manifests are handled by the **MemoryDB** provider.

The example parameter group includes a setting for safe eviction of stale keys - `maxmemory-policy: allkeys-lru` - this is likely not important for MemoryDB as it is database-Redis, but provides an example of how to configure parameters.

Manifests 5, 6 and 7 are slightly more complicated, but first the relationships between the different component objects; incorrect or missing relationships will cause errors of different kinds.

* Cluster object definitions have references to security groups, subnet groups, parameter groups and ACLs
* ACL object definitions include users, but can also be empty without any users
* User object definitions get passwords from Kubernetes Secrets

From a deployment perspective, cluster objects reference ACL objects, ACL objects reference user objects and user object reference Secrets.

**5**\
A user needs to have a Secret with the password of 16-128 characters available as per the documentation. Each user has a so-called *access string* which defines access permissions. An example of such a string is `on ~* &* +@all`, which is the default 'allow everything' rule. This is probably not what we want; application developers and/or owners should be able provide the settings they want as it's likely they have something they are already using. Access permissions are defined per user, so there should not be any issues with multiple applications sharing a single MemoryDB instance.

A connection secret can be saved, but only contains the user password - no endpoint or other details - so it seems to be a 'work in progress'.

**6**\
ACL object definitions can be 'empty' - as in without any users - but cannot refer to non-existent users as reconciliation will generate a lot of error messages. Multiple users can be included in a single ACL.

There is a option to save a connection secret here also, but nothing happens so this too appears to be a work in progress.

**7**\
Clusters do not need to have security groups, subnet groups, parameter groups or ACLs defined - default subnet groups, parameter groups and ACLs will be used if these are not defined while the cluster will be created without a security group; what will cause errors during reconciliation is referring to non-existent objects.

The default ACL is called `openAccess` and provides unrestricted access, which is probably not a good idea even in a devolopment environment.

The cluster endpoint and ARN values are stored as key/value fields in the status section of the Crossplane Cluster object so will need to be extracted using e.g. `kubectl` and `jq`.

This is another place where it feels a little unfinished - for example RDS instances provisioned by Crossplane store endpoint and account details in a single secret.

The cluster endpoint of a MemoryDB cluster called `memorydb-cluster` (the name used in the demo stack) can for example be retrieved using the following command:
> `kubectl get cluster.memorydb.aws.upbound.io/memorydb-cluster -o json | jq -r '.status.atProvider.clusterEndpoint[].address'`

## Backups
MemoryDB has fairly basic backup - automatic snapshots that are taken once every 24 hours and can be retained for up to 35 days, and manual backups that can be retained for as long as required. There does not appear to be any form of so called point-in-time-recovery available.

For the demo stack, automated backups are enabled and retention is set to 7 days.

Amazon's own documentation on MemoryDB snapshots and restore is [here](https://docs.aws.amazon.com/memorydb/latest/devguide/snapshots.html)

## Use cases

### Create MemoryDB cluster
Subnet groups cannot be updated so the correct subnet group must be configured from the outset; security groups, the parameter group and the ACL can be updated so are less critical, but for security reasons an empty ACL and a security group with restricted access should be configured to override the default settings as these are not very secure.

Other cluster settings - instance size, number of replicas per shard, snapshot window for automated backups, maintenance window etc - can also be changed. The demo stack uses the smallest instance size and some generic settings to show how it can be done. One thing to remember is that the maintenance window and the snapshot window must not overlap.

### Update a cluster
Basically everything except the subnet group and the region can be changed so long as anything referred to by the manifest exists - e.g. ACLs, parameter groups and security groups - otherwise reconciliation will fail.

### Delete a cluster
In the demo stack the Crossplane `deletionPolicy:` key is set to the value `Delete` for all objects, which means that deleting the Crossplane object will also delete the AWS resource. This is perhaps a little risky in a production environment where the recommendation is to instead use the value `Orphan` so that AWS resources are left in place after deletion of Crossplane objects.

Otherwise just delete; clusters are the last layer of the stack so can be deleted without taking into consideration other layers.

### ACL management
As ACLs are nothing more than a list of existing user objects which are to have access to the database that the ACL is assigned to, creation/update/deletion are all relatively easy to handle as long as there are no references to objects that don't exist. This means, for example, that users need to be removed from any ACLs they belong to before being deleted and ACLs need to be removed from any clusters that are using them before ACLs are deleted.

### Add a new user
Create new user objects, including password secrets and access strings, then assign them to ACLs. Access will be granted to new users on any cluster that is using an ACL that includes those users.

### Update a user
Updating an access string for a user is simple - just update the manifest and redeploy.

Changing passwords is a little more complicated as updating the secret does not trigger a reconciliation (which makes sense as it's not part of a Crossplane object). Instead you can use two key/value pairs in a secret and update the user object to point from one password entry to another - the Kubernetes Secret manifest in the demo stack created by the script has two password entries as it was used to verify password rotation. Updating the password reference value in the user manifest will trigger reconciliation and an update of the user's password value.

### Delete a user
Delete the entry for that user from any ACL that is using it before deleting the user object otherwise Crossplane will generate error messages when it tries to reconcile with a non-existant object.




