# xTea Pilot WDL — Verily Workbench / GP2

Roda o xTea 0.1.9 em amostras WGS do GP2 via Cromwell no Verily Workbench,
com Google Batch API como executor. Submete e esquece: não depende de você
manter o laptop aberto.

## O que ele faz

Pra cada amostra na input list:

1. Baixa CRAM + referência pra uma VM dedicada do Google Batch
2. Roda o xTea (gen scripts + align + collect + call + filter) pras famílias
   L1, Alu, SVA (configurável)
3. Copia os VCFs finais + relatórios pro bucket de output do workspace
4. Destrói a VM (você só paga pelo tempo de execução)

Saída final no bucket:

```
gs://.../xtea_outputs/
└── SAMPLE_ID/
    ├── L1/
    │   ├── SAMPLE_ID_LINE1.vcf
    │   ├── candidate_disc_filtered_cns.txt
    │   └── run_L1.log
    ├── Alu/
    │   └── SAMPLE_ID_ALU.vcf
    ├── SVA/
    │   └── SAMPLE_ID_SVA.vcf
    └── runtime_stats.tsv
```

## Setup inicial (uma vez só)

### 1. Criar bucket de output no workspace

Na UI do Workbench: **Resources → + Cloud resource → New Cloud Storage bucket**.

Nome sugerido: `gp2-r11-xtea-results-cdoamaral` (tem que ser globalmente único
no GCS, então prefixa com algo distintivo).

### 2. Subir os resources do xTea pro bucket

O xTea precisa de dois arquivos auxiliares que ele não distribui no container:

**rep_lib_annotation.tar.gz** (~500 MB) — biblioteca de consensus sequences
pras famílias de TE. Download:

```bash
# Do repo do xTea (ver https://github.com/parklab/xTea#step-21):
wget https://github.com/parklab/xTea/releases/download/v0.1.9/rep_lib_annotation.tar.gz
```

**gencode.v33.annotation.gff3** — GENCODE v33 é o que o xTea original usa
pra classificação (exônico / intrônico / intergênico). Qualquer versão
recente do GENCODE funciona; usa a v33 pra bater com os papers:

```bash
wget https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_33/gencode.v33.annotation.gff3.gz
gunzip gencode.v33.annotation.gff3.gz
```

Sobe os dois pro seu bucket do workspace (pode ser num subdir
`xtea-resources/` — o Workbench tem um terminal com `gsutil` já instalado):

```bash
gsutil cp rep_lib_annotation.tar.gz gs://SEU-BUCKET/xtea-resources/
gsutil cp gencode.v33.annotation.gff3 gs://SEU-BUCKET/xtea-resources/
```

### 3. Descobrir o path dos CRAMs do GP2 R11

No Workbench, acessa o workspace compartilhado do GP2. Os CRAMs ficam em um
bucket que o admin do GP2 deu acesso (nome varia por release). Normalmente
tem um manifest `.tsv` listando todos os samples; de lá você pega:

- `sample_id` (ou equivalente)
- path do CRAM
- path do CRAI (índice)

Pro teste, escolhe UMA amostra aleatória e anota os paths.

### 4. Adicionar o WDL ao workspace

Tem 2 opções (ver
[docs](https://support.workbench.verily.com/docs/guides/workflows/cromwell/)):

**Opção A — via GCS bucket:**
```bash
gsutil cp xtea_gp2.wdl gs://SEU-BUCKET/wdls/
```
Depois na UI: **Workflows → Add workflow → escolhe o bucket e o .wdl**.

**Opção B — via GitHub (recomendado se você quer versionar):**
Comita o WDL num repo GitHub, conecta a conta em
**Profile → Linked accounts → GitHub**, e aponta pro repo quando adicionar
o workflow.

## Rodando o teste

### 1. Preparar o input JSON

Abre `xtea_gp2.inputs.test.json`, substitui todos os `TODO-...` pelos paths
reais:

- `cram`/`crai` — da amostra que você escolheu do GP2
- `rep_lib_tar_gz` / `gene_annotation_gff3` — do seu bucket de resources
- `output_bucket_prefix` — do seu bucket de output

### 2. Submeter

**Via UI:**
1. Workflows → seleciona `xtea_gp2` → **New job**
2. **Enter job details** → nome: `xtea-pilot-test-001`
3. **Prepare inputs** → cola o JSON editado (ou preenche campo por campo)
4. Marca **Enable call caching** (economiza se você re-submeter)
5. **Submit**

**Via CLI:** (do app do Workbench, em um terminal)
```bash
wb workflow job run xtea_gp2 \
  --inputs-file xtea_gp2.inputs.test.json \
  --name xtea-pilot-test-001 \
  --enable-call-caching
```

### 3. Monitorar

A execução dispara UMA VM do Google Batch (pros parâmetros default: 8 CPUs,
32 GB RAM, 200 GB disk). Você pode fechar o laptop.

Status a qualquer momento:

**Via UI:** Workflows → Job status → clica no job.

**Via CLI:**
```bash
wb workflow job list
wb workflow job describe <job-id>
```

### 4. Ver os resultados

Depois que o job terminar:

```bash
# Lista o que foi gerado
gsutil ls -r gs://SEU-BUCKET/xtea_outputs/TEST_SAMPLE_001/

# Estatísticas de runtime
gsutil cat gs://SEU-BUCKET/xtea_outputs/TEST_SAMPLE_001/runtime_stats.tsv

# Baixa os VCFs pra analisar localmente
gsutil -m cp -r gs://SEU-BUCKET/xtea_outputs/TEST_SAMPLE_001 ./
```

## Interpretando o benchmark

Depois do primeiro run, você vai ter:

| Métrica | Onde olhar | Comparar com Setonix |
|---|---|---|
| Tempo total | `runtime_stats.tsv` → `elapsed_human` | tempo do seu sbatch PPMI |
| Memória pico | `runtime_stats.tsv` → `peak_memory_kb` | (não tinha medida equivalente) |
| Custo USD | UI do Cromwell → "Cost" no job detail | N/A (HPC é free pra você) |
| N variantes L1 | `grep -vc '^#' L1/*_LINE1.vcf` | seu output PPMI |
| N variantes Alu | `grep -vc '^#' Alu/*_ALU.vcf` | seu output PPMI |
| N variantes SVA | `grep -vc '^#' SVA/*_SVA.vcf` | seu output PPMI |

**Critério de validação:** se os counts bateram com o que você viu no PPMI
(mesma ordem de magnitude, perfil similar de SVLEN), o WDL tá correto.

## Estimativa de custo e tempo

Pra 1 amostra WGS 30x CRAM:

| Item | Estimativa |
|---|---|
| Tempo xTea (3 famílias) | 6–14h |
| VM recommended | n2-standard-8 (8 vCPU, 32 GB) |
| Custo on-demand | US$ 0.40/h × 10h ≈ **US$ 4** |
| Custo preemptible | US$ 0.10/h × 10h ≈ **US$ 1** |
| Storage (200 GB SSD × 10h) | US$ 0.23/h ≈ **US$ 2** |
| **Total por amostra** | **~US$ 3–6** |

Extrapolando:

| Dataset | Estimativa total |
|---|---|
| 1 amostra (pilot) | ~US$ 5 |
| 100 amostras (bloco de testes) | ~US$ 500 |
| 5.000 amostras (GP2 R11 subset) | ~US$ 25.000 |

**IMPORTANTE:** essas são estimativas grosseiras. Rode o pilot de 1
amostra primeiro, colete o número real de `runtime_stats.tsv`, depois
multiplica pra saber quanto vai custar o batch inteiro.

## Troubleshooting

### Job falha com "out of memory"
Aumenta `memory_gb` no input JSON (32 → 48 → 64). Amostras com cobertura
alta ou muita heterogeneidade podem pedir mais.

### Job falha com "disk full"
Aumenta `disk_gb` (200 → 300). O xTea gera muitos intermediários; CRAMs
grandes (~40 GB) + BAM extraído podem passar dos 200 GB.

### "xtea: command not found" dentro do container
O binário do container BioContainers é `xtea` (lowercase) e tá no PATH por
default. Se mudou, veja `singularity exec xtea_0.1.9.sif which xtea`.

### Preemption atrapalha jobs longos
Se o xTea roda 12h e é preemptado na hora 11, perde quase tudo (xTea
não tem checkpoint nativo). Pra amostras que sabidamente demoram muito,
considere `preemptible_tries: 0` — mais caro, mas mais confiável.

### Quer re-rodar sem pagar de novo
`Enable call caching` na submissão. Se os inputs (hash dos CRAMs etc.) não
mudaram, o Cromwell pega do cache e não re-executa.

## Próximos passos depois do pilot

1. Confirmar contagens de variantes vs PPMI Setonix
2. Medir tempo/custo real (vem do `runtime_stats.tsv`)
3. Preparar input JSON com 10–20 amostras pro batch médio
4. Decidir `preemptible_tries` baseado na duração observada
5. (Paralelo) Criar WDL equivalente de MELT pra comparar
6. Rodar merge populacional (`x_vcf_merger.py -P`) depois que o batch
   terminar, baixando os VCFs individuais pro bucket e consolidando
