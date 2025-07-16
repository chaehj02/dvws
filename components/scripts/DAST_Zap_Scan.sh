#!/bin/bash
source components/dot.env

CONTAINER_NAME="${BUILD_TAG}"
IMAGE_TAG="${DYNAMIC_IMAGE_TAG}"
ZAP_SCRIPT="${ZAP_SCRIPT:-zap_scan.sh}"
ZAP_BIN="${ZAP_BIN:-$HOME/zap/zap.sh}"
startpage="${1:-}"

echo "🔧 ECR_REPO: $ECR_REPO"

# ✅ EXPOSE 포트 감지 함수
get_exposed_port() {
    local image="$1"
    local exposed_port

    exposed_port=$(docker inspect --format='{{range $k, $v := .Config.ExposedPorts}}{{$k}} {{end}}' "$image" | grep -oE '^[0-9]+' | head -n1)

    if [[ -n "$exposed_port" ]]; then
        echo "[+] EXPOSE 감지된 포트: $exposed_port"
        echo "$exposed_port"
    else
        echo "[!] EXPOSE 포트 없음. 기본값 80 사용"
        echo "80"
    fi
}

# ✅ 사용 가능한 외부 포트 탐색
for try_port in {8081..8089}; do
  echo "[DEBUG] 시도 중: $try_port"
  set +e
  lsof_stdout=$(lsof -iTCP:$try_port -sTCP:LISTEN -n -P 2>/dev/null)
  set -e

  if [ -z "$lsof_stdout" ] && ! docker ps --format '{{.Ports}}' | grep -q ":$try_port->"; then
    port=$try_port
    zap_port=$((port + 10))
    echo "[+] 사용 가능한 외부 포트: $port / ZAP 포트: $zap_port"
    break
  fi
done

# ZAP 준비
containerName="$CONTAINER_NAME"
zap_pidfile="zap_${zap_port}.pid"
zap_log="zap_${zap_port}.log"
zapJson="zap_test_${BUILD_TAG}.json"
timestamp=$(date +"%Y%m%d_%H%M%S")

mkdir -p "$HOME/zap/zap_workdir_${zap_port}/plugin"
ZAP_BIN_DIR=$(dirname "$ZAP_BIN")
cp "${ZAP_BIN_DIR}/plugin/"*.zap "$HOME/zap/zap_workdir_${zap_port}/plugin/"

echo "[*] Docker 이미지 pull 중..."
docker pull "$ECR_REPO:$IMAGE_TAG"

# 내부 포트 감지
internal_port=$(get_exposed_port "$ECR_REPO:$IMAGE_TAG")

# internal_port가 비어 있거나 숫자가 아닌 경우 기본값 지정
if [ -z "$internal_port" ] || ! [[ "$internal_port" =~ ^[0-9]+$ ]]; then
    echo "❗ 내부 포트 감지 실패 → 기본값 80 사용"
    internal_port="80"
else
    echo "[INFO] 내부 포트 설정 완료: $internal_port"
fi


# ✅ docker run 실행 시 반드시 내부 포트를 포함하여 -p 옵션 사용
echo "[*] 컨테이너 실행: $containerName (외부 $port → 내부 $internal_port)"
docker run -d --name "$containerName" -p "${port}:${internal_port}" "$ECR_REPO:$IMAGE_TAG"
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

# S3 업로드
echo "[*] S3 업로드 시도..."
if aws s3 cp "$ZAP_RESULT_FILE" "s3://${S3_BUCKET_DAST}/${s3_key}" --region "$REGION"; then
    echo "✅ S3 업로드 완료"
else
    echo "⚠️ S3 업로드 실패 (무시됨)"
fi

# 리포트 저장
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
