version 1.0

## ============================================================================
## xtea_gp2.wdl
##
## Roda xTea 0.1.9 em amostras WGS do GP2 (CRAM em GCS) e copia os VCFs
## por família (L1, Alu, SVA) pra um bucket GCS de destino.
##
## Estrutura:
##   - workflow XteaBatch: recebe uma lista de samples, scatter por amostra
##   - task RunXtea: roda o xTea em UMA amostra (gen1 + gen2 + collect)
##   - task PublishResults: copia VCFs finais pro bucket de output
##
## Referência:
##   Container: quay.io/biocontainers/xtea:0.1.9--hdfd78af_0
##   Repo: https://github.com/parklab/xTea
##
## Recursos típicos por amostra (WGS 30x, GRCh38):
##   - CPU: 8
##   - RAM: 32 GB (com margem; tem amostra que pede mais)
##   - Disk: 200 GB local SSD (CRAM ~30 GB + BAM convertido ~60 GB + intermediários)
##   - Tempo: 6-14h (depende muito da cobertura e da fração de reads discordantes)
## ============================================================================

workflow XteaBatch {
    input {
        # Lista de amostras a processar. Cada entrada: sample_id + cram + crai
        Array[SampleInfo] samples

        # Referência GRCh38 (use a do bucket público da Broad)
        File reference_fa
        File reference_fai

        # Bibliotecas de repeats do xTea (vem no repo, tem no bucket público também)
        # https://github.com/parklab/xTea#step-21-download-pre-processed-repeat-library
        File rep_lib_tar_gz

        # Gene annotation (GENCODE v33 gff3 — usado pelo xTea pra classificação)
        File gene_annotation_gff3

        # Bucket onde vamos publicar os resultados finais
        # Ex: "gs://gp2-r11-xtea-results-cdoamaral/xtea_outputs"
        String output_bucket_prefix

        # Qual families chamar. "-y 7" = L1+Alu+SVA (bitflag: 1=L1, 2=Alu, 4=SVA).
        # "-y 15" = L1+Alu+SVA+HERV.
        Int te_families_flag = 7

        # Janela de clustering de breakpoints (bp).
        # Se null/omitido, usa o default do próprio xTea (recomendado pro benchmark).
        Int? clip_window

        # Runtime tunables
        Int cpu = 8
        Int memory_gb = 32
        Int disk_gb = 200
        Int preemptible_tries = 2
        Int max_retries = 1

        # Container
        String xtea_docker = "quay.io/biocontainers/xtea:0.1.9--hdfd78af_0"
    }

    scatter (sample in samples) {
        call RunXtea {
            input:
                sample_id            = sample.sample_id,
                cram                 = sample.cram,
                crai                 = sample.crai,
                reference_fa         = reference_fa,
                reference_fai        = reference_fai,
                rep_lib_tar_gz       = rep_lib_tar_gz,
                gene_annotation_gff3 = gene_annotation_gff3,
                te_families_flag     = te_families_flag,
                clip_window          = clip_window,
                cpu                  = cpu,
                memory_gb            = memory_gb,
                disk_gb              = disk_gb,
                preemptible_tries    = preemptible_tries,
                max_retries          = max_retries,
                docker               = xtea_docker
        }

        call PublishResults {
            input:
                sample_id      = sample.sample_id,
                results_tar_gz = RunXtea.results_tar_gz,
                output_bucket_prefix = output_bucket_prefix
        }
    }

    output {
        # Array de paths GCS dos resultados publicados (1 por amostra)
        Array[String] published_paths = PublishResults.published_path
        # Array de arquivos de runtime stats pra benchmarking
        Array[File]   runtime_stats   = RunXtea.runtime_stats
    }

    meta {
        description: "Run xTea TE caller on a batch of WGS CRAMs from GP2 / PPMI"
        author: "cdoamaral"
    }
}

## ----------------------------------------------------------------------------
## Struct dos inputs por amostra
## ----------------------------------------------------------------------------
struct SampleInfo {
    String sample_id
    File   cram
    File   crai
}

## ----------------------------------------------------------------------------
## Task: RunXtea
##
## Executa o pipeline completo do xTea numa única amostra. Passos:
##   1. Localiza CRAM + reference (o Cromwell baixa automaticamente)
##   2. Gera sample_id.list e bam_list.txt (formato que o xTea espera)
##   3. Chama `xtea -i sample.list -b bam_list.txt ...` -> gera scripts
##   4. Executa os scripts gerados (gen1, gen2, collect_reads, pipeline)
##   5. Empacota L1/Alu/SVA VCFs + logs num tar.gz pra publicar depois
## ----------------------------------------------------------------------------
task RunXtea {
    input {
        String sample_id
        File   cram
        File   crai
        File   reference_fa
        File   reference_fai
        File   rep_lib_tar_gz
        File   gene_annotation_gff3
        Int    te_families_flag
        Int?   clip_window
        Int    cpu
        Int    memory_gb
        Int    disk_gb
        Int    preemptible_tries
        Int    max_retries
        String docker
    }

    command <<<
        set -euo pipefail

        # -------- Setup: timing e logging --------
        START_TIME=$(date +%s)
        echo "[xtea-wdl] Sample: ~{sample_id}"
        echo "[xtea-wdl] Start: $(date)"
        echo "[xtea-wdl] Host: $(hostname)  CPUs: $(nproc)  Mem: $(free -h | awk '/^Mem:/{print $2}')"

        WORK="$(pwd)"
        mkdir -p "${WORK}/xtea_work" "${WORK}/output"

        # -------- Extrai rep_lib --------
        # xTea precisa da pasta rep_lib_annotation/ descompactada
        echo "[xtea-wdl] Extracting rep_lib..."
        tar -xzf ~{rep_lib_tar_gz} -C "${WORK}/xtea_work/"
        REP_LIB_DIR=$(find "${WORK}/xtea_work" -maxdepth 2 -type d -name "rep_lib_annotation" | head -1)
        if [ -z "${REP_LIB_DIR}" ]; then
            echo "ERROR: rep_lib_annotation directory not found in tarball" >&2
            exit 1
        fi
        echo "[xtea-wdl] rep_lib at: ${REP_LIB_DIR}"

        # -------- Monta sample list e bam list --------
        # Formato sample.list: um sample_id por linha
        echo "~{sample_id}" > "${WORK}/sample_id.list"

        # Formato bam_list.txt: sample_id<TAB>bam_path<TAB>(opcional)path_2
        # xTea aceita CRAM no mesmo campo do BAM desde a 0.1.9
        printf '%s\t%s\n' '~{sample_id}' '~{cram}' > "${WORK}/bam_list.txt"

        # -------- Gera os scripts do xTea --------
        # -i: sample list
        # -b: bam list
        # -x: output prefix dir
        # -l: rep_lib path
        # -r: reference FASTA
        # -g: gene annotation GFF3
        # -y: bitflag das famílias (7 = L1+Alu+SVA)
        # -f: steps (5907 = todos: gen_scripts + align + collect + call + filter)
        # -p: output dir
        # -o: output submit script name
        # -n: ncores
        # -m: memoria em GB
        # --xtea: força path interno do xtea no container
        echo "[xtea-wdl] Generating xTea scripts..."
        # Nota: --flklen é omitido propositalmente pra usar o default do xTea.
        # Se o input clip_window foi fornecido, adiciona como argumento extra.
        FLKLEN_ARG=""
        if [ -n "~{clip_window}" ]; then
            FLKLEN_ARG="--flklen ~{clip_window}"
        fi

        # shellcheck disable=SC2086
        # (FLKLEN_ARG precisa expandir em dois tokens — word splitting intencional)
        xtea \
            -i "${WORK}/sample_id.list" \
            -b "${WORK}/bam_list.txt" \
            -x null \
            -l "${REP_LIB_DIR}" \
            -r ~{reference_fa} \
            -g ~{gene_annotation_gff3} \
            -y ~{te_families_flag} \
            -f 5907 \
            -p "${WORK}/xtea_work" \
            -o "${WORK}/submit_jobs.sh" \
            -n ~{cpu} \
            -m ~{memory_gb} \
            ${FLKLEN_ARG}

        # -------- Executa o pipeline --------
        # O script gerado tem comandos tipo:
        #   cd <sample>/L1 && sh run_xTEA_pipeline.sh
        # Rodamos um por família em sequência (poderia paralelizar se RAM permitisse,
        # mas xTea já usa múltiplos cores internamente — melhor não competir)
        echo "[xtea-wdl] Running xTea pipeline..."

        SAMPLE_DIR="${WORK}/xtea_work/~{sample_id}"
        if [ ! -d "${SAMPLE_DIR}" ]; then
            echo "ERROR: xtea didn't create sample dir at ${SAMPLE_DIR}" >&2
            ls -la "${WORK}/xtea_work/"
            exit 1
        fi

        # Flags: 1=L1, 2=Alu, 4=SVA, 8=HERV
        for family in L1 Alu SVA HERV; do
            case "${family}" in
                L1)   bit=1 ;;
                Alu)  bit=2 ;;
                SVA)  bit=4 ;;
                HERV) bit=8 ;;
            esac
            # Checa se o bit tá setado no flag
            if [ $(( ~{te_families_flag} & bit )) -ne 0 ]; then
                FAMILY_DIR="${SAMPLE_DIR}/${family}"
                if [ -d "${FAMILY_DIR}" ] && [ -f "${FAMILY_DIR}/run_xTEA_pipeline.sh" ]; then
                    echo "[xtea-wdl] --- Running ${family} ---"
                    cd "${FAMILY_DIR}"
                    bash run_xTEA_pipeline.sh 2>&1 | tee "run_${family}.log"
                    cd "${WORK}"
                else
                    echo "[xtea-wdl] WARNING: ${FAMILY_DIR}/run_xTEA_pipeline.sh not found — skipping ${family}"
                fi
            fi
        done

        # -------- Coleta os VCFs finais e empacota --------
        echo "[xtea-wdl] Collecting results..."
        mkdir -p "${WORK}/output/~{sample_id}"

        # Estrutura esperada de output do xTea:
        #   <sample>/<family>/<sample>_<FAMILY>.vcf
        #   <sample>/<family>/*.txt (relatórios)
        #   <sample>/<family>/*.log
        for family in L1 Alu SVA HERV; do
            FAMILY_DIR="${SAMPLE_DIR}/${family}"
            if [ -d "${FAMILY_DIR}" ]; then
                DEST="${WORK}/output/~{sample_id}/${family}"
                mkdir -p "${DEST}"
                # VCFs finais
                find "${FAMILY_DIR}" -maxdepth 2 -name "*.vcf" -exec cp {} "${DEST}/" \; 2>/dev/null || true
                # Relatórios e logs (úteis pra troubleshooting mas não pra análise)
                find "${FAMILY_DIR}" -maxdepth 2 -name "*.txt" -exec cp {} "${DEST}/" \; 2>/dev/null || true
                find "${FAMILY_DIR}" -maxdepth 2 -name "run_${family}.log" -exec cp {} "${DEST}/" \; 2>/dev/null || true
            fi
        done

        # -------- Runtime stats --------
        END_TIME=$(date +%s)
        ELAPSED=$(( END_TIME - START_TIME ))
        PEAK_MEM_KB=$(grep VmPeak /proc/self/status | awk '{print $2}' || echo "NA")

        cat > "${WORK}/output/~{sample_id}/runtime_stats.tsv" <<EOF
sample_id	~{sample_id}
elapsed_seconds	${ELAPSED}
elapsed_human	$(printf '%dh %dm %ds' $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60)))
peak_memory_kb	${PEAK_MEM_KB}
cpu_count	~{cpu}
memory_gb_requested	~{memory_gb}
disk_gb_requested	~{disk_gb}
te_families_flag	~{te_families_flag}
xtea_container	~{docker}
end_date	$(date -Iseconds)
EOF

        cp "${WORK}/output/~{sample_id}/runtime_stats.tsv" "${WORK}/runtime_stats.tsv"

        echo "[xtea-wdl] Runtime stats:"
        cat "${WORK}/runtime_stats.tsv"

        # -------- Empacota tudo num tarball só pra facilitar upload --------
        echo "[xtea-wdl] Creating tarball..."
        cd "${WORK}/output"
        tar -czf "${WORK}/~{sample_id}_xtea_results.tar.gz" "~{sample_id}/"
        cd "${WORK}"

        echo "[xtea-wdl] Done. Elapsed: ${ELAPSED}s"
    >>>

    output {
        File results_tar_gz = "~{sample_id}_xtea_results.tar.gz"
        File runtime_stats  = "runtime_stats.tsv"
    }

    runtime {
        docker:      docker
        cpu:         cpu
        memory:      "~{memory_gb} GB"
        disks:       "local-disk ~{disk_gb} SSD"
        preemptible: preemptible_tries
        maxRetries:  max_retries
    }
}

## ----------------------------------------------------------------------------
## Task: PublishResults
##
## Copia o tarball de resultados pro bucket de output, descompactando
## na estrutura final {sample}/{family}/*.vcf.
##
## Usa uma task separada (leve, 1 CPU, 1 GB) pra não desperdiçar a VM
## cara do xTea fazendo upload.
## ----------------------------------------------------------------------------
task PublishResults {
    input {
        String sample_id
        File   results_tar_gz
        String output_bucket_prefix
    }

    command <<<
        set -euo pipefail

        # Descompacta localmente
        mkdir -p staging
        tar -xzf ~{results_tar_gz} -C staging/

        # Remove trailing slash se tiver
        DEST="~{output_bucket_prefix}"
        DEST="${DEST%/}"

        # Copia recursivo pro bucket
        echo "[publish] Uploading to ${DEST}/~{sample_id}/"
        gsutil -m cp -r staging/~{sample_id}/* "${DEST}/~{sample_id}/"

        echo "${DEST}/~{sample_id}/" > published_path.txt
    >>>

    output {
        String published_path = read_string("published_path.txt")
    }

    runtime {
        docker:      "google/cloud-sdk:slim"
        cpu:         1
        memory:      "2 GB"
        disks:       "local-disk 50 HDD"
        preemptible: 3
    }
}
