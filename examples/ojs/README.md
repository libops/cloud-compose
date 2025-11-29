# OJS

Deploy OJS to Google Cloud

## Usage

Create the production VM

```
terraform init
terraform apply -target=module.production
```

The staging VM then relies on a snapshot of the public files docker volume. This is to allow staging to mirror production.

So need wait until snapshot schedule executes (~1h) OR get a snapshot of the production docker volume disk immediately. then the rest of the terraform runs can just execute as normal

```
terraform apply
```
