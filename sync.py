import os
import sys
import tarfile
from huggingface_hub import HfApi, hf_hub_download

api = HfApi()
repo_id = os.getenv("HF_DATASET")
token = os.getenv("HF_TOKEN")
FILENAME = "latest_backup.tar.gz"

def restore():
    try:
        if not repo_id or not token:
            print("Skip Restore: HF_DATASET or HF_TOKEN not set")
            return
        
        # 直接下载最新文件
        print(f"Downloading {FILENAME} from {repo_id}...")
        path = hf_hub_download(repo_id=repo_id, filename=FILENAME, repo_type="dataset", token=token)
        
        with tarfile.open(path, "r:gz") as tar:
            tar.extractall(path="/root/.openclaw/")
        print(f"Success: Restored from {FILENAME}")
        return True
    except Exception as e:
        # 如果是第一次运行，仓库里没文件，报错是正常的
        print(f"Restore Note: No existing backup found or error: {e}")

def backup():
    try:
        if not repo_id or not token:
            print("Skip Backup: HF_DATASET or HF_TOKEN not set")
            return

        with tarfile.open(FILENAME, "w:gz") as tar:
            # 备份关键数据
            paths_to_backup = [
                "/root/.openclaw/sessions",
                "/root/.openclaw/agents/main/sessions",
                "/root/.openclaw/credentials",
                "/root/.openclaw/openclaw.json",
            ]
            for p in paths_to_backup:
                if os.path.exists(p):
                    arcname = p.replace("/root/.openclaw/", "")
                    tar.add(p, arcname=arcname)
        
        # 上传并覆盖
        api.upload_file(
            path_or_fileobj=FILENAME,
            path_in_repo=FILENAME,
            repo_id=repo_id,
            repo_type="dataset",
            token=token
        )
        print(f"Backup {FILENAME} Success (Overwritten).")
    except Exception as e:
        print(f"Backup Error: {e}")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "backup":
        backup()
    else:
        restore()