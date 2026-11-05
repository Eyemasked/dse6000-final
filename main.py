from pathlib import Path

from dash import Dash, dcc, html
import pandas as pd
import plotly.express as px

app = Dash(__name__)
server = app.server

DATA_DIR = Path(__file__).resolve().parent / "data"

# See https://plotly.com/python/px-arguments/ for more options
fruit_df = pd.DataFrame(
    {
        "Fruit": ["Apples", "Oranges", "Bananas", "Apples", "Oranges", "Bananas"],
        "Amount": [4, 1, 2, 2, 4, 5],
        "City": ["SF", "SF", "SF", "Montreal", "Montreal", "Montreal"],
    }
)

bar_fig = px.bar(fruit_df, x="Fruit", y="Amount", color="City", barmode="group")

gapminder_df = pd.read_csv(DATA_DIR / "sample.csv")

scatter_fig = px.scatter(
    gapminder_df,
    x="gdp per capita",
    y="life expectancy",
    size="population",
    color="continent",
    hover_name="country",
    log_x=True,
    size_max=60,
)

app.layout = html.Div(
    [
        html.H1("Hello Dash"),
        html.Div("Dash: A web application framework for your data."),
        dcc.Graph(
            id="example-graph",
            figure=bar_fig,
        ),
        html.Div("Dash: Another example chart"),
        dcc.Graph(
            id="example-graph2",
            figure=scatter_fig,
        ),
    ]
)

if __name__ == "__main__":
    app.run(debug=True, port=8080)

