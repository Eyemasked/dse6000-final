from dash import Dash, html

app = Dash(__name__)
server = app.server

app.layout = html.Div(
    children=[
        html.H1(children="Hello Dash"),
        html.Div(
            children=[
                "html.Div adds an HTML div element. ",
                html.A(
                    "More here",
                    href="https://developer.mozilla.org/en-US/docs/Web/HTML/Element/div",
                    target="_blank",
                ),
            ]
        ),
        html.Div(
            children="The example above also uses an 'a' tag to create an external link."
        ),
        html.A(
            "More here",
            href="https://developer.mozilla.org/en-US/docs/Web/HTML/Element/a",
            target="_blank",
        ),
        html.P(
            "Note that Instead of writing raw HTML, you use Dash HTML components "
            "named after standard HTML tags. For example, this is a paragraph (p) element."
        ),
    ]
)

if __name__ == "__main__":
    app.run(debug=True, port=8080)

