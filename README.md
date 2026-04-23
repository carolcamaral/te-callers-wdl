# te-callers-wdl

WDL workflows for running transposable element (TE) callers at scale on
Google Cloud / Verily Workbench, with Google Batch API as the task executor.

## Context

Part of a research project characterizing non-reference TE insertions
(Alu, LINE-1, SVA) and their association with Parkinson's disease risk
and progression, using the GP2 (Global Parkinson's Genetics Program) WGS
cohort.

The workflows in this repo are designed to scale from a single-sample
pilot (to benchmark time / cost / memory) up to the full GP2 Release 11
batch (several thousand samples). They run unattended on Google Batch
API VMs — no local machine or HPC login node needs to stay open during
execution.

## Workflows

| Workflow | Status | Purpose |
|---|---|---|
| `xtea_gp2.wdl` | ✅ Pilot-ready | Calls TE insertions with [xTea](https://github.com/parklab/xTea) (L1, Alu, SVA, HERV) |
| `melt_gp2.wdl` | 🚧 Planned | Calls TE insertions with [MELT](https://melt.igs.umaryland.edu/) — for cross-tool comparison |

Both workflows are designed with the same skeleton (scatter by sample,
stage CRAM from Requester Pays bucket, publish results to a destination
bucket) so that runtime and output metrics are directly comparable.

## Repository layout

```
te-callers-wdl/
├── xtea_gp2.wdl                  # xTea workflow (3 tasks: StageCram, RunXtea, PublishResults)
├── xtea_gp2.inputs.test.json     # Example inputs for a 1-sample pilot
├── README.md                     # This file
└── docs/
    └── xtea_pilot_walkthrough.md # Step-by-step guide for the xTea pilot run
```

## xTea workflow — quick overview

**Inputs**
- A list of samples (`sample_id`, CRAM path, CRAI path) in GCS
- GRCh38 reference (FASTA + FAI)
- xTea resources (`rep_lib_annotation.tar.gz` + GENCODE v33 GFF3)
- Destination bucket prefix for output VCFs
- Flag for Requester Pays buckets (required for GP2 CRAM bucket)

**Per-sample pipeline**
1. **StageCram** — downloads CRAM + CRAI using `gsutil -u PROJECT` (to support
   Requester Pays billing)
2. **RunXtea** — runs the full xTea pipeline (script generation → alignment →
   read collection → calling → filtering) for the requested TE families
3. **PublishResults** — uploads the final VCFs, reports, and runtime stats
   to the destination bucket

**Outputs per sample**
```
{output_bucket_prefix}/{sample_id}/
├── L1/{sample_id}_LINE1.vcf
├── Alu/{sample_id}_ALU.vcf
├── SVA/{sample_id}_SVA.vcf
└── runtime_stats.tsv   # elapsed time, peak memory, VM config — used for benchmarking
```

**Default resources** (tunable per job): 8 vCPU, 32 GB RAM, 200 GB local SSD,
n2-standard-8 on Google Batch, with 2 preemptible retries + 1 on-demand fallback.

## Running the pilot (first-time use)

See `docs/xtea_pilot_walkthrough.md` for a step-by-step guide, but the
high-level recipe is:

1. **Prepare xTea resources** (once per project): download
   `rep_lib_annotation.tar.gz` from the xTea repo and `gencode.v33.annotation.gff3`
   from GENCODE, then upload both to your workspace bucket.
2. **Link this repo to Verily Workbench**: in Workbench, go to
   *Profile → Linked accounts → GitHub*, authorize, then in your workspace
   go to *Workflows → + Add workflow → Git repository* and select
   `xtea_gp2.wdl` from this repo.
3. **Edit inputs**: copy `xtea_gp2.inputs.test.json` and fill in the paths
   specific to your workspace (sample CRAM, rep_lib, gene annotation,
   output bucket).
4. **Submit**: from the Workflows UI, click *New job*, paste the inputs,
   submit. You can close your laptop — the workflow runs on Google Batch
   VMs independent of your session.
5. **Review**: expected wall-time is 7–13 hours for a single 30× WGS CRAM
   (~13 GB). Read `runtime_stats.tsv` from the output bucket to decide
   resource sizing for the full batch.

## Requirements

- A Verily Workbench workspace with:
  - Read access to the GP2 CRAM bucket (`gs://gp2_crams` — Requester Pays)
  - A workspace bucket to store xTea resources and output VCFs
  - The Cromwell engine enabled (default on Workbench)
- A linked GitHub account (for the Workbench to pull this WDL)


These are order-of-magnitude estimates. Run the 1-sample pilot first and
refine from `runtime_stats.tsv` before submitting the full batch.

## References

- xTea — Chu C. et al., *Comprehensive identification of transposable element
  insertions using multiple sequencing technologies*, **Nat Commun** 12, 3836 (2021).
  <https://doi.org/10.1038/s41467-021-24041-8>
- MELT — Gardner E.J. et al., *The Mobile Element Locator Tool (MELT): population-scale
  mobile element discovery and biology*, **Genome Res** 27, 1916–1929 (2017).
- GP2 — Global Parkinson's Genetics Program. <https://gp2.org>
- Verily Workbench Cromwell docs — <https://support.workbench.verily.com/docs/guides/workflows/cromwell/>

## License

MIT (see LICENSE file). xTea and MELT have their own licenses — consult
their respective repositories before non-academic use.
