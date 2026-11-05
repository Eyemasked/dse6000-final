import base64
import io

from dash import Dash, html
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import seaborn as sns

app = Dash(__name__)
server = app.server


def create_titanic_plot() -> str:
    titanic_df = sns.load_dataset("titanic")
    grid = sns.catplot(
        x="sex",
        y="age",
        hue="survived",
        col="pclass",
        data=titanic_df,
        kind="bar",
        errorbar=None,
        height=4,
        aspect=0.7,
    )
    grid.set_axis_labels("", "Mean Age")

    with io.BytesIO() as buf:
        plt.savefig(buf, format="png", bbox_inches="tight")
        plt.close(grid.figure)
        encoded = base64.b64encode(buf.getbuffer()).decode("utf-8")

    return f"data:image/png;base64,{encoded}"


app.layout = html.Div(
    [
        html.H2("Matplotlib / Seaborn Figure in Dash"),
        html.Img(id="example", src=create_titanic_plot()),
    ]
)

if __name__ == "__main__":
    app.run(debug=True, port=8080)

