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

## Getting the BLS Data (every teammate, once)

The BLS datasets are **not committed** to git (`data/bls_*.csv` is in `.gitignore`), so after cloning you need to download them yourself. This runs locally and does not need gcloud:

```bash
source myenv/bin/activate          # with requirements.txt installed
# Optional: higher API limits with a free key from https://data.bls.gov/registrationEngine/
# export BLS_API_KEY=your_key_here
python3 fetch_bls_data.py
```

This writes four files to `data/`: `bls_timeseries.csv`, `bls_qcew_county.csv`, `bls_oews_msa.csv` and `bls_oews_national.csv`. Whoever runs `./run.sh` to deploy must have these files locally, because they are uploaded with the build.

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

## Best Practices & Troubleshooting Guide

If your deployment or application fails on GCP, open **Logs Explorer** (by searching for `Logs Explorer` in the top search bar of the Google Cloud Console, or navigating to **Cloud Run $\rightarrow$ `dash-gcp-app` $\rightarrow$ Logs**) to inspect the error stack trace. Below are the most common issues and best practices:

1. **Pre-Train and Save ML Models Ahead of Time (`pickle` / `joblib`) — Do NOT Train at App Startup:**
   * If your dashboard uses a `scikit-learn` or `statsmodels` model, **do not train the model inside `main.py` when the Dash app starts**. Training on startup slows down container cold-starts and can exceed Cloud Run memory/startup timeouts.
   * Instead, write a standalone training script (e.g., `train_model.py`), run `python3 train_model.py` once from the terminal to save the trained model into `data/model.pkl` using `pickle` or `joblib`, and load `data/model.pkl` inside `main.py` to run predictions:
     ```python
     import joblib
     from pathlib import Path

     DATA_DIR = Path(__file__).resolve().parent / "data"
     model = joblib.load(DATA_DIR / "model.pkl")
     ```
2. **Always Use Relative Paths for Data & Model Files:**
   * Never use hardcoded absolute paths from your laptop or Cloud Shell (such as `/Users/yourname/...` or `/home/...`). They will fail with `FileNotFoundError` inside the Cloud Run container.
   * Place datasets and saved `.pkl` models inside the `data/` folder and reference them via `Path(__file__).resolve().parent / "data" / "myfile.csv"` (or `'data/myfile.csv'`).
3. **Do Not Write Persistent Files to the Local Filesystem at Runtime:**
   * Treat the Cloud Run container filesystem as read-only at runtime. Any files written to disk by a running container are stored in temporary memory and wiped when the instance scales down. Use `io.BytesIO()` for in-memory plots/downloads.
4. **Keep `requirements.txt` Updated When Installing New Packages:**
   * Whenever you install a new package locally with `pip install <package>` (or `conda`), you **must** add that package to `requirements.txt`. Cloud Build only installs packages listed in `requirements.txt`.
   * To check the exact version of an installed package in your active virtual environment, run `python3 -m pip list` or `python3 -m pip freeze` ([pip freeze docs](https://pip.pypa.io/en/stable/cli/pip_freeze/)).
5. **Increasing Memory or CPU for Larger Datasets:**
   * By default, `run.sh` deploys the Cloud Run service with `1Gi` of memory (`--memory=1Gi`) and `1` vCPU (`--cpu=1`). If your dataset or ML model requires more memory, edit `--memory=2Gi` (or `4Gi`) in `run.sh` and redeploy with `./run.sh --force`.
6. **GCP Account & Billing Credits:**
   * Ensure you are authenticated with your **personal Gmail account** rather than an institutional/university email account (such as `@umich.edu`), which often restricts project creation and IAM permissions.
   * You can check your remaining GCP credits by searching for **Billing** in the top search bar of the GCP Console. **Do NOT enter your personal credit card information at any time**—if you run low on credits, request a course coupon.
7. **Port 8080 Already in Use & Cloud Shell Lockout:**
   * Running `python3 main.py` starts a development server accessible only to you. Always shut it down with **`Ctrl+C`** when you finish testing. Leaving it running in Google Cloud Shell will exhaust your weekly quota and lock your Cloud Shell environment.
   * If you try to run `python3 main.py` while another instance is already running, you will see a `Port 8080 is in use` error. If you closed the terminal tab that started the server, restart Cloud Shell via the three-dots icon (**`⋮` $\rightarrow$ Restart**) in the top navigation bar, or restart your local computer.
   * Once your app is deployed to Cloud Run via `./run.sh`, your public `.run.app` URL stays live on Google's infrastructure—you can safely stop your local server and close Cloud Shell.
8. **Commit and Push Your Code to Git Regularly:**
   * Especially when working in Google Cloud Shell, commit and push your changes (`git add . && git commit -m "..." && git push`) periodically so you never lose your work.

---

## Project Configuration & Example Files

1. **`main.py`**: Primary Dash application entrypoint exposing `server = app.server` for Gunicorn.
2. **`requirements.txt`**: Top-level Python dependencies (`dash`, `plotly`, `pandas`, `numpy`, `scipy`, `scikit-learn`, `statsmodels`, `matplotlib`, `seaborn`, `gunicorn`).
3. **`Dockerfile` & `run.sh`**: Used to containerize and deploy the application to **Google Cloud Run**.
4. **`data/`**: Directory for datasets and pre-trained model files loaded relative to the project root (see `main.py` using `pathlib.Path`).
5. **`examples/`**: Standalone scripts demonstrating core Dash features (stop any running server with `Ctrl+C` before starting another example on port `8080`):
   * `python3 examples/eg1-simple.py` – Basic HTML layout components
   * `python3 examples/eg2-app-callback.py` – Reactive callbacks with numeric inputs
   * `python3 examples/eg3-matplotlib-image.py` – Rendering a Seaborn/Matplotlib figure in Dash
   * `python3 examples/eg4-dropdown.py` – Interactive cross-filtering with dropdowns, radio items, and sliders

## Useful References

* **Dash Layout Guide:** [https://dash.plotly.com/layout](https://dash.plotly.com/layout)
* **Dash Core Components (`dcc`):** [https://dash.plotly.com/dash-core-components](https://dash.plotly.com/dash-core-components)
* **Plotly Express Arguments:** [https://plotly.com/python/px-arguments/](https://plotly.com/python/px-arguments/)
* **Creating & Updating Figures in Plotly:** [https://plotly.com/python/creating-and-updating-figures/](https://plotly.com/python/creating-and-updating-figures/)
* **Plotly Pandas Backend (`df.plot()`):** [https://plotly.com/python/pandas-backend/](https://plotly.com/python/pandas-backend/)
