# assets/

Static files served to Discord.

## `venmo-qr.png` (for the tip feature)

**This file is deliberately not committed** — it is gitignored. A Venmo "Venmo Me"
QR encodes a personal payment identity, so it is supplied locally at deploy time
rather than stored in a public repository. The tip feature is entirely opt-in and
none of its infrastructure is created when it is disabled.

To enable it:

1. In the Venmo app, open your profile QR ("Venmo Me" code) and save it as an image.
2. Save it here as **`venmo-qr.png`** (local only — `.gitignore` keeps it out of git).
3. Set `venmo_tip_url = "https://venmo.com/u/your-handle"` in `infra/terraform.tfvars`.
4. `terraform apply` — the image uploads to S3 and Terraform wires the public object
   URL into the SSM params (read by the instance) and the Lambda env vars (read by
   the bot).

Leave `venmo_tip_url` empty to disable the feature — no S3 bucket, no bucket policy,
and no image are created.

## Why the bucket is public

Discord renders embed images by fetching the URL anonymously from its own servers,
so the object must be publicly readable. The bucket policy therefore grants
`s3:GetObject` to `Principal: "*"` — but **scoped to the single `venmo-qr.png` key**,
not to `/*`. ACLs stay blocked; only the explicit policy grants access. See
`docs/SECURITY.md` for the full reasoning and the accepted-risk entry.
