import io
import json
import os
import re
import zipfile

import pandas as pd
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

BLS_API_V1 = "https://api.bls.gov/publicAPI/v1/timeseries/data/"
BLS_API_V2 = "https://api.bls.gov/publicAPI/v2/timeseries/data/"

# BLS bot-protection rejects default `python-requests/...` and `curl/...` User-Agent
# headers with HTTP 403 / HTML block pages on bulk downloads (QCEW/OEWS) and API calls;
# an explicit non-default User-Agent identifying the project avoids automated blocks.
HEADERS = {
    "User-Agent": "Mozilla/5.0 (compatible; StudentResearchProject/1.0; +https://www.bls.gov)"
}

FATAL_API_PATTERNS = [
    r"Series does not exist",
    r"Invalid Series",
    r"daily threshold",
    r"provided by the User is invalid",
]

MONTHLY_PERIOD_RE = re.compile(r"M(0[1-9]|1[0-2])")

# ==============================================================================
# 1. TIME SERIES: CPI, CES, Unemployment, and JOLTS (via BLS Public Data API)
# ==============================================================================
SERIES_MAP = {
    # CPI-U (Seasonally Adjusted)
    "CUSR0000SA0": "CPI_All_Items",
    "CUSR0000SA0L1E": "CPI_Core_Ex_Food_Energy",
    "CUSR0000SAF1": "CPI_Food",
    "CUSR0000SAH1": "CPI_Shelter",
    "CUSR0000SA0E": "CPI_Energy",
    # CES & Labor Force (Seasonally Adjusted)
    "CES0000000001": "Total_Nonfarm_Payrolls_k",
    "CES0500000003": "Avg_Hourly_Earnings_Private",
    "LNS14000000": "Unemployment_Rate_Pct",
    # JOLTS (Total Nonfarm, Seasonally Adjusted, Thousands)
    "JTS000000000000000JOL": "JOLTS_Job_Openings_k",
    "JTS000000000000000HIL": "JOLTS_Hires_k",
    "JTS000000000000000QUL": "JOLTS_Quits_k",
    "JTS000000000000000LDL": "JOLTS_Layoffs_Discharges_k",
}

QCEW_INDUSTRIES = {
    "10": "Total_All_Industries",
    "31_33": "Manufacturing",
    "44_45": "Retail_Trade",
    "51": "Information_Tech_Media",
    "62": "Healthcare_Social_Assistance",
    "72": "Accommodation_Food_Services",
}


class BLSFeedError(RuntimeError):
    """Raised when a BLS endpoint returns an invalid status, response, or series ID."""


def create_session() -> requests.Session:
    """Create a requests Session with BLS-compatible headers and transient retry handling."""
    session = requests.Session()
    session.headers.update(HEADERS)
    retry = Retry(
        total=3,
        backoff_factor=1.0,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=("GET", "POST"),
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


def parse_value(raw) -> float | None:
    """Parse a numeric BLS observation; treat suppression dashes/blanks as None."""
    if raw is None:
        return None
    text = str(raw).strip()
    if text in ("", "-", "–", "—"):
        return None
    return float(text.replace(",", ""))


def save_csv(df: pd.DataFrame, out_path: str) -> None:
    """Write a DataFrame to CSV, creating parent directories if needed."""
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    df.to_csv(out_path, index=False)


def fetch_bls_timeseries(
    series_map: dict[str, str],
    start_year: int,
    end_year: int,
    api_key: str | None = None,
    session: requests.Session | None = None,
) -> pd.DataFrame:
    """Fetch monthly BLS time series observations for ``series_map`` across
    ``[start_year, end_year]``."""
    if start_year > end_year:
        raise ValueError(f"start_year ({start_year}) must be <= end_year ({end_year})")

    series_ids = list(series_map.keys())
    bad_ids = [sid for sid in series_ids if sid != sid.upper()]
    if bad_ids:
        raise BLSFeedError(f"Invalid series IDs (expected uppercase): {bad_ids}")

    key = api_key if api_key is not None else os.getenv("BLS_API_KEY")
    url = BLS_API_V2 if key else BLS_API_V1
    max_series = 50 if key else 25
    max_span = 20 if key else 10  # v1 caps each request at 10 years & 25 series

    own_session = session is None
    sess = session or create_session()
    rows = []
    seen = set()
    try:
        for i in range(0, len(series_ids), max_series):
            id_chunk = series_ids[i : i + max_series]
            for chunk_start in range(start_year, end_year + 1, max_span):
                chunk_end = min(chunk_start + max_span - 1, end_year)
                payload = {
                    "seriesid": id_chunk,
                    "startyear": str(chunk_start),
                    "endyear": str(chunk_end),
                }
                if key:
                    payload["registrationkey"] = key  # BLS v2 requires lowercase key name

                resp = sess.post(
                    url,
                    data=json.dumps(payload),
                    # BLS v1/v2 API requires JSON Content-Type; include HEADERS so
                    # User-Agent is sent on POST too.
                    headers={"Content-Type": "application/json", **HEADERS},
                    timeout=60,
                )
                content_type = resp.headers.get("Content-Type", "")
                if resp.status_code != 200 or "json" not in content_type.lower():
                    raise BLSFeedError(
                        f"HTTP {resp.status_code} from BLS API: {resp.text[:200]!r}"
                    )

                data = resp.json()
                msgs = data.get("message") or []
                if data.get("status") != "REQUEST_SUCCEEDED" or any(
                    re.search(pattern, msg, re.IGNORECASE)
                    for msg in msgs
                    for pattern in FATAL_API_PATTERNS
                ):
                    raise BLSFeedError(f"{data.get('status')}: {msgs}")

                for series in (data.get("Results") or {}).get("series", []):
                    sid = series["seriesID"]
                    seen.add(sid)
                    for item in series.get("data", []):
                        period = item.get("period", "")
                        if not MONTHLY_PERIOD_RE.fullmatch(period):
                            continue  # Keep monthly observations M01..M12, drop M13 annual averages
                        footnotes = "; ".join(
                            f.get("text", "").strip()
                            for f in item.get("footnotes", [])
                            if f and f.get("text")
                        )
                        rows.append(
                            {
                                "series_id": sid,
                                "metric": series_map[sid],
                                "year": int(item["year"]),
                                "month": int(period[1:]),
                                "date": f"{item['year']}-{period[1:]}-01",
                                "value": parse_value(item.get("value")),
                                "footnotes": footnotes,
                            }
                        )
    finally:
        if own_session:
            sess.close()

    missing = sorted(set(series_ids) - seen)
    if missing:
        print(f"  Warning: no series returned for {missing}")

    columns = ["series_id", "metric", "year", "month", "date", "value", "footnotes"]
    df = pd.DataFrame(rows, columns=columns)
    df["date"] = pd.to_datetime(df["date"])
    return df.sort_values(["metric", "date"]).reset_index(drop=True)


# ==============================================================================
# 2. QCEW: County-Level Employment & Weekly Wages by Industry (CSV Slice API)
# ==============================================================================
def fetch_qcew_counties(
    year: int,
    quarter: str,
    industries: dict[str, str],
    session: requests.Session | None = None,
) -> pd.DataFrame:
    """
    Fetch county-level QCEW data for the requested year, quarter ('1'-'4' or 'a'),
    and industries.

    agglvl_code 70 = County, Total Covered (own_code 0)
    agglvl_code 74 = County, NAICS 2-digit Sector (own_code 5 = Private)
    """
    own_session = session is None
    sess = session or create_session()
    frames = []
    try:
        for code, label in industries.items():
            url = f"https://data.bls.gov/cew/data/api/{year}/{quarter}/industry/{code}.csv"
            print(f"  Downloading QCEW {year} Q{quarter} - {label}...")
            resp = sess.get(url, headers=HEADERS, timeout=60)
            content_type = resp.headers.get("Content-Type", "")
            if resp.status_code != 200 or "html" in content_type.lower():
                raise BLSFeedError(
                    f"HTTP {resp.status_code} fetching QCEW {code}: {resp.text[:200]!r}"
                )

            df = pd.read_csv(
                io.StringIO(resp.text),
                dtype={"area_fips": str, "industry_code": str},
                low_memory=False,
            )
            # Keep county-level rows only (drop US/state/MSA aggregates & suppressed rows)
            if code == "10":
                mask = (df["agglvl_code"] == 70) & (df["own_code"] == 0)
            else:
                mask = (df["agglvl_code"] == 74) & (df["own_code"] == 5)
            df = df[mask & (df["disclosure_code"].fillna("") != "N")].copy()
            df["industry_label"] = label
            frames.append(df)
    finally:
        if own_session:
            sess.close()

    if not frames:
        return pd.DataFrame()

    combined = pd.concat(frames, ignore_index=True)
    keep_cols = [
        "area_fips",
        "own_code",
        "industry_code",
        "industry_label",
        "agglvl_code",
        "year",
        "qtr",
        "annual_avg_estabs",
        "annual_avg_emplvl",
        "total_annual_wages",
        "annual_avg_wkly_wage",
        "avg_annual_pay",
        "qtrly_estabs",
        "month1_emplvl",
        "month2_emplvl",
        "month3_emplvl",
        "total_qtrly_wages",
        "avg_wkly_wage",
    ]
    available = [c for c in keep_cols if c in combined.columns]
    return combined[available]


# ==============================================================================
# 3. OEWS: Occupation Wages & Percentiles (Metro Areas & National)
# ==============================================================================
def fetch_oews_zip(
    two_digit_year: str,
    geo_suffix: str,
    session: requests.Session | None = None,
) -> pd.DataFrame:
    """
    Fetch and parse an OEWS Excel archive for ``two_digit_year`` (e.g. '24') and
    ``geo_suffix`` ('ma', 'st', 'nat').
    """
    url = f"https://www.bls.gov/oes/special-requests/oesm{two_digit_year}{geo_suffix}.zip"
    print(f"  Downloading {url}...")

    own_session = session is None
    sess = session or create_session()
    try:
        resp = sess.get(url, headers=HEADERS, timeout=120)
        if resp.status_code != 200:
            raise BLSFeedError(f"HTTP {resp.status_code} fetching OEWS {url}")
    finally:
        if own_session:
            sess.close()

    try:
        with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
            xlsx_files = [name for name in zf.namelist() if name.lower().endswith(".xlsx")]
            if not xlsx_files:
                raise BLSFeedError(f"No .xlsx file found inside {url}")
            with zf.open(xlsx_files[0]) as f:
                df = pd.read_excel(f, engine="openpyxl", dtype={"AREA": str, "area": str})
    except zipfile.BadZipFile as exc:
        raise BLSFeedError(f"Invalid zip archive returned from {url}") from exc

    df.columns = [c.strip().lower() for c in df.columns]

    # Convert BLS suppression symbols ('*', '#', '**') to NaN in numeric columns
    numeric_cols = [
        "tot_emp",
        "emp_prse",
        "jobs_1000",
        "loc_quotient",
        "h_mean",
        "a_mean",
        "mean_prse",
        "h_pct10",
        "h_pct25",
        "h_median",
        "h_pct75",
        "h_pct90",
        "a_pct10",
        "a_pct25",
        "a_median",
        "a_pct75",
        "a_pct90",
    ]
    for col in numeric_cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    return df


def main(output_dir: str = "data") -> None:
    """Download all BLS datasets and save them as CSVs under ``output_dir``."""
    os.makedirs(output_dir, exist_ok=True)

    with create_session() as session:
        print("Fetching CPI, CES, Unemployment, and JOLTS time series...")
        ts_df = fetch_bls_timeseries(SERIES_MAP, start_year=2015, end_year=2025, session=session)
        ts_path = os.path.join(output_dir, "bls_timeseries.csv")
        save_csv(ts_df, ts_path)
        print(f"Saved {ts_path} ({len(ts_df):,} rows)")

        print("Fetching QCEW county-level wages...")
        qcew_df = fetch_qcew_counties(
            year=2024, quarter="a", industries=QCEW_INDUSTRIES, session=session
        )
        qcew_path = os.path.join(output_dir, "bls_qcew_county.csv")
        save_csv(qcew_df, qcew_path)
        print(f"Saved {qcew_path} ({len(qcew_df):,} rows)")

        print("Fetching OEWS May 2024 Metro & National occupational wage data...")
        oews_msa = fetch_oews_zip("24", "ma", session=session)
        oews_msa_path = os.path.join(output_dir, "bls_oews_msa.csv")
        save_csv(oews_msa, oews_msa_path)
        print(f"Saved {oews_msa_path} ({len(oews_msa):,} rows)")

        oews_nat = fetch_oews_zip("24", "nat", session=session)
        oews_nat_path = os.path.join(output_dir, "bls_oews_national.csv")
        save_csv(oews_nat, oews_nat_path)
        print(f"Saved {oews_nat_path} ({len(oews_nat):,} rows)")


if __name__ == "__main__":
    main()
