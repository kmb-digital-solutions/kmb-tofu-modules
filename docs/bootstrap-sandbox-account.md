# Bootstrap Sandbox Account

> One-time setup of a dedicated AWS sandbox account for the N-cycle test
> harness. Run by an operator with management-account access.

## Why a dedicated sandbox

The N-cycle test creates, destroys, and re-creates AWS resources on every
run. Running it against a production workload account would be both noisy
(misleading alarms) and dangerous (a buggy module test could nuke
something real). The sandbox is the safe blast radius.

Recommended sandbox customer slug: `sandbox-co` (mentioned in the
requirements doc's Open Questions as the convention).

## Steps

1. **Create the customer in Singular Console.** Slug `sandbox-co`, name
   `Sandbox Co`, email `ops+sandbox@singular-systems.com`.

2. **Provision a lower account.** Customer detail → Accounts tab →
   Provision account → Tier: Lower. This runs through the standard B2.2
   flow and lands an account named `sandbox-co-lower` under the
   `Customers/sandbox-co/` OU. Record the 12-digit account id.

3. **Verify reachability.** Wait for the row to reach `reachable` status
   (60–120 seconds). The console's STS assume-role check succeeded.

4. **Configure CI access to the sandbox.** The N-cycle workflow needs to
   assume `OrganizationAccountAccessRole` in the sandbox account. Add a
   GitHub Actions OIDC trust policy to the role:

   ```bash
   # From management-account credentials:
   aws iam create-role --role-name kmb-tofu-nightly-runner \
     --assume-role-policy-document file://trust.json

   # trust.json:
   # {
   #   "Version": "2012-10-17",
   #   "Statement": [{
   #     "Effect": "Allow",
   #     "Principal": {
   #       "Federated": "arn:aws:iam::<sandbox-id>:oidc-provider/token.actions.githubusercontent.com"
   #     },
   #     "Action": "sts:AssumeRoleWithWebIdentity",
   #     "Condition": {
   #       "StringEquals": {
   #         "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
   #         "token.actions.githubusercontent.com:sub": "repo:kmb-digital-solutions/kmb-tofu-modules:ref:refs/heads/main"
   #       }
   #     }
   #   }]
   # }
   ```

5. **Add the sandbox account id to GitHub secrets.**
   `SANDBOX_AWS_ACCOUNT_ID = <12-digit-id>`. The `n-cycle-test.yml`
   workflow reads this and assumes
   `arn:aws:iam::<id>:role/kmb-tofu-nightly-runner`.

6. **Provision the per-application sandbox state bucket.** Each
   application root writes its OpenTofu state to S3. For the sandbox,
   create a bucket `sandbox-co-lower-tfstate` in the sandbox account:

   ```bash
   aws s3 mb s3://sandbox-co-lower-tfstate --region us-east-1
   aws s3api put-bucket-encryption --bucket sandbox-co-lower-tfstate ...
   aws s3api put-public-access-block --bucket sandbox-co-lower-tfstate ...
   aws s3api put-bucket-versioning --bucket sandbox-co-lower-tfstate \
     --versioning-configuration Status=Enabled
   ```

7. **Run the N-cycle harness manually once** to confirm the trust + state
   plumbing works end-to-end:

   ```bash
   AWS_PROFILE=management \
   SANDBOX_AWS_ACCOUNT_ID=<id> \
   scripts/n_cycle_test.sh traincover sandbox-co
   ```

   First successful run takes ~30 minutes. Subsequent cycles in the same
   run are faster because modules are already cached locally.

## Cost expectations

Running the full N-cycle suite (all application roots, 3 cycles each)
against the sandbox account: ~$2-4 per nightly run, dominated by NAT
Gateway hour-prorated minimums during the apply window. Daily cost is
roughly $60-120/month. Acceptable for the catch-rate the test provides.

## Tear-down

The sandbox account stays. The point of a sandbox is that it's stable.
Individual test runs clean themselves up between cycles; the account
itself is provisioned once and reused.

To retire the sandbox entirely:

1. Drop the OIDC trust policy on `kmb-tofu-nightly-runner`.
2. Manually empty + close the sandbox AWS account from the
   management-account Organizations console.
3. Archive the `sandbox-co` customer in Singular Console.
