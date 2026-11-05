from dash import Dash, Input, Output, dcc, html

app = Dash(__name__)
server = app.server

app.layout = html.Div(
    [
        html.H6("Change the value in the text boxes to see callbacks in action!"),
        html.Div(
            [
                "Input-1: ",
                dcc.Input(id="my-input1", value="2", type="number"),
                html.Br(),
                "Input-2: ",
                dcc.Input(id="my-input2", value="2", type="number"),
            ]
        ),
        html.Br(),
        html.Div(id="my-output"),
    ]
)


@app.callback(
    Output(component_id="my-output", component_property="children"),
    Input(component_id="my-input1", component_property="value"),
    Input(component_id="my-input2", component_property="value"),
)
def multiply(input_value1, input_value2):
    if input_value1 is None or input_value2 is None or input_value1 == "" or input_value2 == "":
        return "Empty"
    try:
        product = float(input_value1) * float(input_value2)
        return f"{input_value1} multiplied by {input_value2} is {product}"
    except ValueError:
        return "Please enter valid numbers."


if __name__ == "__main__":
    app.run(debug=True, port=8080)

