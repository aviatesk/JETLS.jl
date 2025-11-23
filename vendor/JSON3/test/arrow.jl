using Arrow

obj1 = JSON3.read("""
{
    "int": 1,
    "float": 2.1
}
""")

obj2 = JSON3.read("""
{
    "int": 1,
    "float": 2.1,
    "bool1": true,
    "bool2": false,
    "none": null,
    "str": "\\"hey there sailor\\"",
    "arr": [null, 1, "hey"],
    "arr2": [1.2, 3.4, 5.6]
}
""")

obj3 = JSON3.read("""
{
    "int": 1,
    "float": 2.1,
    "bool1": true,
    "bool2": false,
    "none": null,
    "str": "\\"hey there sailor\\"",
    "obj": {
                "a": 1,
                "b": null,
                "c": [null, 1, "hey"],
                "d": [1.2, 3.4, 5.6]
            },
    "arr": [null, 1, "hey"],
    "arr2": [1.2, 3.4, 5.6]
}
""")

tbl = (; json=[obj1, obj2, obj3])

arrow = Arrow.Table(Arrow.tobuffer(tbl))
@test tbl.json == arrow.json
