# Dash GCP Template (Google Cloud Run)

A starter template for building interactive data visualization dashboards with **[Plotly Dash](https://dash.plotly.com/)**, **Pandas**, **Scikit-Learn**, and **Statsmodels**, deployed as a serverless container on **Google Cloud Run**.

> **Deployment Architecture Note:** This project deploys to **Google Cloud Run** (using `Dockerfile`, Cloud Build, and `run.sh`) rather than legacy Google App Engine (`app.yaml`). Do not use `gcloud app deploy` — use `./run.sh` to build and deploy to Cloud Run.

---

## Option 1: Using Google Cloud Shell (Recommended Quickstart)

Google Cloud Shell already comes pre-installed with **Python 3**, **Git**, and the **Google Cloud SDK (`gcloud`)**.

### 1. Clone the Repository, Enter the Folder & Set Up Virtual Environment

Open [Google Cloud Shell](https://shell.cloud.google.com/) and run:

```bash
git clone https://gitlab.com/mobibootcamp/dash-gcp-template.git
cd dash-gcp-template
chmod +x run.sh

# Create and activate a Python virtual environment
python3 -m venv myenv
source myenv/bin/activate

# Install required Python packages
pip install --upgrade pip
pip install -r requirements.txt
```

### 2A. Enable APIs & Run Locally in Cloud Shell

If you want to run the Dash server inside Cloud Shell and preview it in your browser:

```bash
# 1. List your GCP projects, pick a number [1-N], and enable required APIs:
./run.sh --apis-only

# 2. Start the local Dash server on port 8080:
python3 main.py
```

Then click the **Web Preview** button in the top-right corner of Cloud Shell and select **Preview on port 8080**.

> **⚠️ Important — Stopping the Server in Cloud Shell:**
> * Always return to the Cloud Shell terminal and press **`Ctrl+C`** to stop the Dash server when you are done testing. If you do not press `Ctrl+C`, the process will keep running in the background and consume your weekly Cloud Shell hours until Google freezes your compute environment.
> * If you closed or lost the terminal tab that started the process, click the **More (`⋮`)** icon in the top-right corner of the Cloud Shell toolbar and select **Restart** to restart the Cloud Shell machine (or restart your computer).
> * To exit the Python virtual environment when you are done, run:
>   ```bash
>   deactivate
>   ```

### 2B. Or Build & Deploy to Google Cloud Run

To validate syntax, build the container image in Cloud Build, and deploy to a public Cloud Run URL in one step:

```bash
# Prompts you to pick your target GCP project by number [1-N], then builds & deploys:
./run.sh
```

---

## Option 2: Using Your Local Computer

> **Note for Windows Users:** Because `run.sh` is a Bash script that uses Linux commands, please open **Git Bash** (included with [Git for Windows](https://gitforwindows.org/)) or **WSL (Windows Subsystem for Linux)** to run the commands below. When activating the virtual environment in Git Bash on Windows, use `source myenv/Scripts/activate` (or `myenv\Scripts\activate` in Command Prompt / PowerShell).

### 1. Prerequisites

* **Python 3.10+**
* **Git** (on Windows, includes **Git Bash**)
* **Google Cloud SDK (`gcloud`)**

#### Installing & Authenticating the Google Cloud SDK

1. **Download & Install:** Follow the official installer for your OS (Windows, macOS, or Linux) at [https://cloud.google.com/sdk/docs/install](https://cloud.google.com/sdk/docs/install).
   * On macOS/Linux (archive install):
     ```bash
     ./google-cloud-sdk/install.sh
     ```
2. **Initialize & Log In:** Open a new terminal (**Git Bash** / **WSL** on Windows, or Terminal on macOS/Linux) and authenticate both the CLI and Application Default Credentials:
   ```bash
   gcloud init
   gcloud auth application-default login
   gcloud projects list
   ```

### 2. Clone the Repository, Enter the Folder & Install Dependencies

In your terminal (or **Git Bash** on Windows), run:

```bash
git clone https://gitlab.com/mobibootcamp/dash-gcp-template.git
cd dash-gcp-template
chmod +x run.sh

# Create and activate a Python virtual environment (macOS / Linux / WSL):
python3 -m venv myenv
source myenv/bin/activate

# (Or on Windows Git Bash):
# python -m venv myenv
# source myenv/Scripts/activate

# Install dependencies:
pip install --upgrade pip
pip install -r requirements.txt
```

### 3A. Enable APIs & Start the Local Instance

Before running or deploying for the first time, use `./run.sh --apis-only` to select your GCP project `[1-N]` and enable the required Google Cloud APIs (Cloud Run, Artifact Registry, Cloud Build, IAM, and Cloud Logging):

```bash
# 1. Pick your GCP project by number [1-N] and enable required APIs:
./run.sh --apis-only

# 2. Start the local Dash server:
python3 main.py
```

> **Smart Caching Note:** `run.sh` remembers which project has already had its APIs enabled in `~/.dash_gcp_template_deploy.json`. If you already ran `./run.sh --apis-only`, subsequent runs of `./run.sh` or `./run.sh --apis-only` for the same project will automatically skip the API enablement step (pass `--force` if you ever want to re-verify).

Open your browser to:
* `http://localhost:8080` — Dash Application UI

*(With `debug=True` enabled in `main.py`, saving changes to `main.py` automatically hot-reloads the app in your browser).*

#### How to Stop the Service on Your Local Computer

1. **Stop the Dash web server:** Click inside the terminal window where `python3 main.py` is running and press **`Ctrl+C`**.
   * **Important:** If you do not press `Ctrl+C`, the server will continue running in the background and holding port `8080`. If you lost or closed the terminal window that started the process, **restart your computer** (or kill the process occupying port `8080`: `lsof -ti:8080 | xargs kill -9` on macOS/Linux, or `npx kill-port 8080` on Windows).
2. **Deactivate the virtual environment (optional):** When you are finished working on the project, run:
   ```bash
   deactivate
   ```

### 3B. Or Build & Deploy to Google Cloud Run

```bash
# Interactive project selection [1-N] + syntax check, Cloud Build, and Cloud Run deploy
# (Automatically skips API enablement if already enabled for the selected project):
./run.sh

# Fast build & deploy (skip local Python syntax check):
./run.sh --skip-checks

# Force a full rebuild, API re-verification, and redeploy (bypassing cache):
./run.sh --force
```

> **Note on Cloud Run Scaling & Stopping Cloud Services:**
> Cloud Run is configured with `--min-instances=0`, meaning it automatically scales down to **0 instances** when no one is visiting your URL (so it does not consume compute charges while idle). If you want to permanently remove the deployed Cloud Run service, run:
> ```bash
> gcloud run services delete dash-gcp-app --region us-central1
> ```

---

## `run.sh` Options Reference

| Option | Description |
|---|---|
| `--project <id>`, `-p <id>` | Target a specific GCP Project ID directly (skips the interactive numbered prompt). |
| `--apis-only` | Only enable required Google Cloud APIs for the selected project and exit. |
| `--skip-checks` | Skip running local Python syntax validation (`py_compile`). |
| `--force`, `--rebuild`, `-f` | Bypass smart caching and force a complete container rebuild and redeployment. |
| `--help`, `-h` | Display usage and options help. |

---

## Project Configuration & Example Files

1. **`main.py`**: Primary Dash application entrypoint exposing `server = app.server` for Gunicorn.
2. **`requirements.txt`**: Top-level Python dependencies (`dash`, `plotly`, `pandas`, `numpy`, `scipy`, `scikit-learn`, `statsmodels`, `matplotlib`, `seaborn`, `gunicorn`).
3. **`Dockerfile` & `run.sh`**: Used to containerize and deploy the application to **Google Cloud Run**.
4. **`data/`**: Directory for datasets loaded relative to the project root (see `main.py` using `pathlib.Path`).
5. **`examples/`**: Standalone scripts demonstrating core Dash features (stop any running server with `Ctrl+C` before starting another example on port `8080`):
   * `python3 examples/eg1-simple.py` – Basic HTML layout components
   * `python3 examples/eg2-app-callback.py` – Reactive callbacks with numeric inputs
   * `python3 examples/eg3-matplotlib-image.py` – Rendering a Seaborn/Matplotlib figure in Dash
   * `python3 examples/eg4-dropdown.py` – Interactive cross-filtering with dropdowns, radio items, and sliders
