#!/bin/bash
source components/dot.env

CONTAINER_NAME="${BUILD_TAG}"
IMAGE_TAG="${DYNAMIC_IMAGE_TAG}"
ZAP_SCRIPT="${ZAP_SCRIPT:-zap_scan.sh}"
ZAP_BIN="${ZAP_BIN:-$HOME/zap/zap.sh}"
startpage="${1:-}"

echo "🔧 ECR_REPO: $ECR_REPO"

# 🔍 개선된 내부 포트 감지 함수
detect_internal_port() {
    local image="$1"
    local detected_port=""
    local temp_container="temp_port_scan_${RANDOM}"

    echo "[*] 내부 포트 감지를 위해 임시 컨테이너 실행 중..."

    if docker run -d --name "$temp_container" "$image" > /dev/null 2>&1; then
        echo "[DEBUG] 임시 컨테이너 '$temp_container' 시작됨"
        for i in {1..10}; do
            docker top "$temp_container" >/dev/null 2>&1 && break
            sleep 1
        done
        sleep 5

        listening_ports=$(docker exec "$temp_container" sh -c '
            cat /proc/net/tcp 2>/dev/null | tail -n +2 | \
            awk "{print \$2}" | cut -d: -f2 | while read hex; do
                printf "%d\n" 0x$hex
            done | grep -v "^0$" | sort -n | uniq
        ')
        echo "[DEBUG] /proc/net/tcp 감지 결과: $listening_ports"

        if [ -z "$listening_ports" ]; then
            echo "[*] Dockerfile EXPOSE 포트 감지 시도..."
            listening_ports=$(docker inspect --format='{{json .Config.ExposedPorts}}' "$image" | \
                grep -oE '[0-9]+(?=/tcp)' | sort -n | uniq)
            echo "[DEBUG] EXPOSE 포트: $listening_ports"
        fi

        if [ -z "$listening_ports" ]; then
            echo "[*] 로그 기반 포트 감지 시도..."
            listening_ports=$(docker logs "$temp_container" 2>/dev/null | \
                grep -Eo 'port[ :]?[0-9]{2,5}' | grep -o '[0-9]\{2,5\}' | sort -n | uniq)
            echo "[DEBUG] 로그 분석 결과: $listening_ports"
        fi

        docker rm -f "$temp_container" > /dev/null 2>&1

        if [ -n "$listening_ports" ]; then
            for preferred_port in 8080 80 3000 8000 5000 4000 8888 9000 9090; do
                if echo "$listening_ports" | grep -q "^$preferred_port$"; then
                    detected_port="$preferred_port"
                    echo "[+] 우선 포트 선택: $detected_port"
                    echo "$detected_port"
                    return 0
                fi
            done
            detected_port=$(echo "$listening_ports" | head -n1)
            echo "[+] 첫 감지 포트 사용: $detected_port"
            echo "$detected_port"
            return 0
        fi
    else
        echo "[!] 임시 컨테이너 실행 실패"
    fi

    echo "[!] 포트 감지 실패, 기본값 8080 사용"
    echo "8080"
    return 1
}

# ✅ 외부 포트 탐색
for try_port in {8081..8089}; do
  echo "[DEBUG] 시도 중: $try_port"
  set +e
  lsof_stdout=$(lsof -iTCP:$try_port -sTCP:LISTEN -n -P 2>/dev/null)
  lsof_exit_code=$?
  set -e

  if [ $lsof_exit_code -ne 0 ] && [ -z "$lsof_stdout" ]; then
    echo "[DEBUG] 포트 $try_port 사용 안 함"
  elif [ $lsof_exit_code -ne 0 ]; then
    echo "🚨 lsof 예외 발생"
    exit 1
  fi

  if [ -n "$lsof_stdout" ]; then continue; fi

  if docker ps --format '{{.Ports}}' | grep -qE "[0-9\.]*:$try_port->"; then continue; fi

  port=$try_port
  zap_port=$((port + 10))
  echo "[+] 사용 가능한 포트 발견: $port / ZAP 포트: $zap_port"
  break
done

# 📦 ZAP 준비
containerName="${BUILD_TAG}"
zap_pidfile="zap_${zap_port}.pid"
zap_log="zap_${zap_port}.log"
zapJson="zap_test_${BUILD_TAG}.json"
timestamp=$(date +"%Y%m%d_%H%M%S")

mkdir -p "$HOME/zap/zap_workdir_${zap_port}/plugin"
ZAP_BIN_DIR=$(dirname "$ZAP_BIN")
cp "${ZAP_BIN_DIR}/plugin/"*.zap "$HOME/zap/zap_workdir_${zap_port}/plugin/"

echo "[*] Docker 이미지 pull 중..."
docker pull "$ECR_REPO:${DYNAMIC_IMAGE_TAG}"

# 내부 포트 감지
internal_port=$(detect_internal_port "$ECR_REPO:${DYNAMIC_IMAGE_TAG}")
if [ -z "$internal_port" ] || ! [[ "$internal_port" =~ ^[0-9]+$ ]]; then
    echo "❌ 내부 포트 감지 실패, 기본 8080 사용"
    internal_port="8080"
fi

echo "[*] 컨테이너 실행: $containerName (외부 $port → 내부 $internal_port)"
docker run -d --name "$containerName" -p "${port}:${internal_port}" "$ECR_REPO:${DYNAMIC_IMAGE_TAG}"
sleep 3

if ! docker ps | grep "$containerName" > /dev/null; then
    echo "❌ 컨테이너 시작 실패"
    docker logs "$containerName"
    exit 1
fi

# 헬스체크
echo "[*] 헬스체크 중..."
for i in {1..30}; do
    if curl -s --connect-timeout 2 "http://localhost:$port" > /dev/null; then
        echo "[+] 헬스체크 성공"
        break
    fi
    echo "[DEBUG] 헬스체크 실패, 재시도 ($i)"
    sleep 2
done

# ZAP 실행
echo "[*] ZAP 실행"
nohup "$ZAP_BIN" -daemon -port "$zap_port" -host 127.0.0.1 -config api.disablekey=true -dir "zap_workdir_${zap_port}" >"$zap_log" 2>&1 &
echo $! >"$zap_pidfile"

for i in {1..60}; do
  curl -s "http://127.0.0.1:$zap_port" > /dev/null && { echo "[+] ZAP 준비 완료"; break; }
  sleep 1
done 

echo "[*] ZAP 스크립트 실행: $ZAP_SCRIPT"
chmod +x ~/"$ZAP_SCRIPT"
~/"$ZAP_SCRIPT" "$containerName" "$zap_port" "$startpage" "$port"

ZAP_RESULT_FILE="$HOME/zap_${containerName}.json"

if [ ! -f "$ZAP_RESULT_FILE" ]; then
    echo "❌ ZAP 결과 없음: $ZAP_RESULT_FILE"
    ls -la ~/zap_*
    exit 1
fi

echo "[+] ZAP 결과 파일 확인 완료"

echo "[*] S3 업로드 시도..."
if aws s3 cp "$ZAP_RESULT_FILE" "s3://${S3_BUCKET_DAST}/${s3_key}" --region "$REGION"; then
    echo "✅ S3 업로드 완료"
else
    echo "⚠️ S3 업로드 실패 (무시됨)"
fi

# 리포트 디렉터리 생성 및 이동
REPORT_DIR="$HOME/report/${JOB_NAME}"
mkdir -p "$REPORT_DIR"
final_filename="zap_${containerName}_${timestamp}.json"
mv "$ZAP_RESULT_FILE" "$REPORT_DIR/$final_filename" && \
echo "✅ 리포트 저장 완료: $REPORT_DIR/$final_filename"

# 정리
docker rm -f "$containerName" && echo "🧹 컨테이너 정리 완료"
if [ -f "$zap_pidfile" ]; then
  kill "$(cat "$zap_pidfile")" && echo "🧹 ZAP 종료 완료"
  rm -f "$zap_pidfile"
fi
rm -rf "$HOME/zap/zap_workdir_${zap_port}" && echo "🧹 작업 디렉터리 제거 완료"
