#!/usr/bin/env python3
import sys, json, time, os, urllib.request, urllib.parse

QS_LOG_DIR = os.environ.get("QS_LOG_DIR", "/tmp/quickshell/logs")
QS_RUN_WP = os.environ.get("QS_RUN_WALLPAPER_PICKER", "/tmp/quickshell/wallpaper_picker")

LOG_FILE = os.path.join(QS_LOG_DIR, "wallhaven_python_scraper.log")
CONTROL_FILE = os.path.join(QS_RUN_WP, "ddg_search_control")

def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} - {msg}\n")
    except:
        pass

def get_state():
    try:
        with open(CONTROL_FILE, "r") as f:
            return f.read().strip()
    except:
        return "run"

def main():
    log("=== NEW WALLHAVEN SEARCH STARTING ===")
    if len(sys.argv) < 2:
        log("ERROR: No query provided.")
        return

    query = sys.argv[1].strip()
    log(f"Query: '{query}'")

    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "application/json",
        "Referer": "https://wallhaven.cc/"
    }

    links_found = 0

    for page in range(1, 6):
        state = get_state()
        if state == "stop":
            log("Stop signal detected. Exiting cleanly.")
            break
        while state == "pause":
            time.sleep(1)
            state = get_state()

        log(f"Fetching page {page}...")

        params = {
            "q": query,
            "page": page,
            "atleast": "1920x1080",
            "sorting": "relevance",
            "order": "desc"
        }
        url = "https://wallhaven.cc/api/v1/search?" + urllib.parse.urlencode(params)

        try:
            req = urllib.request.Request(url, headers=headers)
            response = urllib.request.urlopen(req, timeout=15)
            data = json.loads(response.read().decode("utf-8"))

            results = data.get("data", [])
            log(f"Successfully parsed JSON. Found {len(results)} raw results.")

            for post in results:
                width = int(post.get("dimension_x", 0))
                height = int(post.get("dimension_y", 0))

                if width >= 1920 and height >= 1080:
                    thumb = post.get("thumbs", {}).get("small")
                    full = post.get("path")
                    if thumb and full:
                        try:
                            sys.stdout.write(f"{thumb}|{full}\n")
                            sys.stdout.flush()
                            links_found += 1
                        except BrokenPipeError:
                            log("Broken pipe detected. Bash script stopped listening. Exiting.")
                            os._exit(0)

        except BrokenPipeError:
            os._exit(0)
        except Exception as e:
            log(f"Error fetching page {page}: {str(e)}")
            break

    log(f"=== SEARCH COMPLETE. Total FHD links: {links_found} ===")

if __name__ == "__main__":
    try:
        os.remove(LOG_FILE)
    except:
        pass

    try:
        main()
        sys.stdout.flush()
    except BrokenPipeError:
        os._exit(0)
    except KeyboardInterrupt:
        os._exit(1)
    except Exception as e:
        log(f"FATAL: {str(e)}")
        os._exit(1)