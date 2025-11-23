@testset "Generate Types" begin

    menu = """
    {
      "menu": {
        "header": "SVG Viewer",
        "items": [
          {
            "id": "Open"
          },
          {
            "id": "OpenNew",
            "label": "Open New"
          },
          {
            "id": "ZoomIn",
            "label": "Zoom In"
          },
          {
            "id": "ZoomOut",
            "label": "Zoom Out"
          },
          {
            "id": "OriginalView",
            "label": "Original View"
          },
          {
            "id": "Quality"
          },
          {
            "id": "Pause"
          },
          {
            "id": "Mute"
          },
          null,
          {
            "id": "Find",
            "label": "Find..."
          },
          {
            "id": "FindAgain",
            "label": "Find Again"
          },
          {
            "id": "Copy"
          },
          {
            "id": "CopyAgain",
            "label": "Copy Again"
          },
          {
            "id": "CopySVG",
            "label": "Copy SVG"
          },
          {
            "id": "ViewSVG",
            "label": "View SVG"
          },
          {
            "id": "ViewSource",
            "label": "View Source"
          },
          {
            "id": "SaveAs",
            "label": "Save As"
          },
          null,
          {
            "id": "Help"
          },
          {
            "id": "About",
            "label": "About Adobe SVG Viewer..."
          }
        ]
      }
    }
    """

    menu_array = """
    [
        {
          "menu": {
            "header": "SVG Viewer",
            "items": [
              {
                "id": "Open"
              },
              {
                "id": "OpenNew",
                "label": "Open New"
              },
              {
                "id": "ZoomIn",
                "label": "Zoom In"
              },
              {
                "id": "ZoomOut",
                "label": "Zoom Out"
              },
              {
                "id": "OriginalView",
                "label": "Original View"
              },
              {
                "id": "Quality"
              },
              {
                "id": "Pause"
              },
              {
                "id": "Mute"
              },
              null,
              {
                "id": "Find",
                "label": "Find..."
              },
              {
                "id": "FindAgain",
                "label": "Find Again"
              },
              {
                "id": "Copy"
              },
              {
                "id": "CopyAgain",
                "label": "Copy Again"
              },
              {
                "id": "CopySVG",
                "label": "Copy SVG"
              },
              {
                "id": "ViewSVG",
                "label": "View SVG"
              },
              {
                "id": "ViewSource",
                "label": "View Source"
              },
              {
                "id": "SaveAs",
                "label": "Save As"
              },
              null,
              {
                "id": "Help"
              },
              {
                "id": "About",
                "label": "About Adobe SVG Viewer..."
              }
            ]
          }
        },
        {
          "menu": {
            "header": "A second item",
            "items": [
              {
                "id": "Open"
              },
              {
                "id": "OpenNew",
                "label": "Open New"
              }
            ]
          }
        }
    ]
    """

    @testset "Object & Array" begin
        json = JSON3.read(menu) # JSON.Object

        # build a type for the JSON
        raw_json_type = JSON3.generate_type(json)
        @test raw_json_type <: NamedTuple

        # turn the type into struct expressions, including replacing sub types with references to a struct
        json_exprs = JSON3.generate_exprs(raw_json_type; root_name = :MyStruct)
        @test length(json_exprs) == 3

        # write the types to a file, then can be edited/included as needed
        path = mktempdir()
        file = joinpath(path, "test_type.jl")
        JSON3.write_exprs(json_exprs, file)
        lines = readlines(file)
        @test length(lines) > 3

        json_arr = JSON3.read(menu_array) # JSON.Array

        # build a type for the JSON
        raw_json_arr_type = JSON3.generate_type(json_arr)
        @test raw_json_arr_type <: Array

        # turn the type into struct expressions, including replacing sub types with references to a struct
        json_arr_exprs = JSON3.generate_exprs(raw_json_arr_type; root_name = :MyStruct)
        @test length(json_arr_exprs) == 3

        # write the types to a file, then can be edited/included as needed
        path = mktempdir()
        file_arr = joinpath(path, "test_arr.jl")
        JSON3.write_exprs(json_arr_exprs, file_arr)
        arr_lines = readlines(file_arr)
        @test length(arr_lines) > 3
        @test arr_lines == lines
    end

    @testset "Write & Read" begin
        path = mktempdir()
        file_path_default = joinpath(path, "default.jl")
        JSON3.writetypes(menu, file_path_default)

        include(file_path_default)
        json = JSON3.read(menu, JSONTypes.Root)

        @test json.menu.header == "SVG Viewer"
        @test length(json.menu.items) > 0
        @test json.menu.items[1].id == "Open"

        @test fieldnames(JSONTypes.Item) == (:id, :label)

        file_path_json = joinpath(path, "menu_array.json")
        Base.write(file_path_json, menu_array)
        file_path_mod = joinpath(path, "my_mod.jl")
        JSON3.writetypes(
            file_path_json,
            file_path_mod;
            module_name = :MyMod,
            root_name = :MenuArray,
        )

        include(file_path_mod)
        json_arr = JSON3.read(menu_array, Vector{MyMod.MenuArray})
        @test length(json_arr) == 2
        @test json_arr[1].menu.header == "SVG Viewer"
    end

    @testset "Struct" begin
        json = """
            [
                {"a": 1, "b": 2, "c": {"d": 4}},
                {"a": "w", "b": 5, "c": {"d": 4}},
                {"a": 3, "b": 4, "c": {"d": 6}},
                {"a": 7, "b": 7, "c": {"d": 7}}
            ]
        """

        path = mktempdir()
        file_path = joinpath(path, "struct.jl")

        JSON3.writetypes(json, file_path; mutable = false)
        include(file_path)
        parsed = JSON3.read(json, Vector{JSONTypes.Root})

        @test !ismutable(parsed[1])
        @test parsed[1].c.d == 4
        @test fieldtype(JSONTypes.Root, 1) == Union{Int64,String}
    end

    @testset "Array of Samples" begin
        jsons = [
            """{"a": 1, "b": 2, "c": {"d": 4}}""",
            """{"a": "w", "b": 5, "c": {"d": 4}}""",
            """{"a": 3, "b": 4, "c": {"d": 6}}""",
            """{"a": 7, "b": 7, "c": {"d": 7}}""",
        ]

        path = mktempdir()
        file_path = joinpath(path, "struct.jl")

        JSON3.writetypes(jsons, file_path; mutable = false)
        include(file_path)
        parsed = JSON3.read(jsons[1], JSONTypes.Root)

        @test !ismutable(parsed)
        @test parsed.c.d == 4

        weird_jsons = [
            """{"a": 1, "b": 2, "c": {"d": 4}}""",
            """[{"a": "w"}, {"b": 5}, {"c": {"d": 4}}]""",
            """{"x": 7}""",
        ]

        JSON3.writetypes(weird_jsons, file_path)
        include(file_path)

        parsed = JSON3.read(weird_jsons[1], JSONTypes.Root)
        @test parsed.c.d == 4

        parsed = JSON3.read(weird_jsons[3], JSONTypes.Root)
        @test parsed.x == 7
        @test !isdefined(parsed, :a)

        # Issue #209
        daily_menu = """{
            "object":"page",
            "date":"23.03.2022"
        }"""
        dishes = """{
            "object":"list",
            "results":[
                {
                    "object":"dish",
                    "name":"Spaghetti"
                }
            ]
        }"""

        JSON3.@generatetypes [daily_menu, dishes]

        new_daily_menu = """{
            "object":"page",
            "date":"24.03.2022"
        }"""
        new_dishes = """{
            "object":"list",
            "results":[
                {
                    "object":"dish",
                    "name":"Pizza"
                }
            ]
        }"""

        menu_struct = JSON3.read(new_daily_menu, JSONTypes.Root)
        dishes_struct = JSON3.read(new_dishes, JSONTypes.Root)
        @test dishes_struct.results[1].object == "dish"
    end

    @testset "Raw Types" begin
        json = """
            [
                {"a": 1, "b": 2, "c": 5},
                {"a": "w", "b": 5, "c": 9},
                {"a": 3, "b": 4, "c": 2},
                {"a": 7, "b": 7, "c": 0}
            ]
        """
        parsed = JSON3.read(json) # JSON.Array

        # build a type for the JSON
        raw_json_type = JSON3.generate_type(parsed)
        @test raw_json_type <: Array

        res = JSON3.read(json, raw_json_type)
        @test isa(res, raw_json_type)

        @test res[4].b == 7

        json = """{"a": 1, "b": 2, "c": 5}"""
        parsed = JSON3.read(json) # JSON.Object

        # build a type for the JSON
        raw_json_type = JSON3.generate_type(parsed)
        @test raw_json_type <: NamedTuple

        res = JSON3.read(json, raw_json_type)
        @test isa(res, raw_json_type)

        @test res.b == 2

        empty_json = "[]"
        raw_json_type = JSON3.generate_type(JSON3.read(empty_json))
        @test raw_json_type === Vector{Any}

        two_json = """[[], [\"hello\"]]"""
        raw_json_type = JSON3.generate_type(JSON3.read(two_json))
        @test raw_json_type === Vector{Vector{String}}

        @test JSON3.unify(Any, Any) == Any
        @test JSON3.unify(Any, Int64) == Int64
        @test JSON3.unify(Int64, Any) == Int64
        @test JSON3.unify(Int64, String) == Union{Int64,String}
        @test JSON3.unify(Float64, Union{Int64,String}) == Union{Float64,Int64,String}
        @test JSON3.unify(Float64, Real) == Real
        @test JSON3.unify(Float64, Union{Int64,Float64}) == Union{Int64,Float64}
        @test JSON3.unify(Union{Int64,Float64}, Float64) == Union{Int64,Float64}
        @test JSON3.unify(Float64, Float64) == Float64
        @test JSON3.unify(Vector{Int64}, Vector{Int64}) == Vector{Int64}
        @test JSON3.unify(NamedTuple{(:d,),Tuple{Int64}}, NamedTuple{(:d,),Tuple{Int64}}) ==
              NamedTuple{(:d,),Tuple{Int64}}
        @test JSON3.unify(
            NamedTuple{(:d,),Tuple{Int64}},
            NamedTuple{(:d,),Tuple{String}},
        ) == NamedTuple{(:d,),Tuple{Union{Int64,String}}}
        @test JSON3.unify(
            Union{Nothing,NamedTuple{(:d,),Tuple{Int64}}},
            NamedTuple{(:d,),Tuple{String}},
        ) == Union{Nothing,NamedTuple{(:d,),Tuple{Union{Int64,String}}}}
        @test JSON3.unify(
            Union{Nothing,NamedTuple{(:d,),Tuple{Int64}},String},
            NamedTuple{(:d,),Tuple{String}},
        ) == Union{Nothing,NamedTuple{(:d,),Tuple{Union{Int64,String}}},String}
        @test JSON3.unify(
            Union{Nothing,Vector{NamedTuple{(:d,),Tuple{Int64}}}},
            Vector{NamedTuple{(:d,),Tuple{String}}},
        ) == Union{Nothing,Vector{NamedTuple{(:d,),Tuple{Union{Int64,String}}}}}
    end

    @testset "Pascal Case" begin
        @test JSON3.pascalcase(:items) == :Item
        @test JSON3.pascalcase(:i) == :I
        @test JSON3.pascalcase(:is) == :I
        @test JSON3.pascalcase(:daisies) == :Daisie # don't let perfect be the enemy of good?
        @test JSON3.pascalcase(:ties) == :Tie
        @test JSON3.pascalcase(:my_types) == :MyType
        @test JSON3.pascalcase(:witness) == :Witness
    end

    @testset "Macro" begin
        JSON3.@generatetypes(menu)
        json = JSON3.read(menu, JSONTypes.Root)

        @test json.menu.header == "SVG Viewer"
        @test length(json.menu.items) > 0
        @test json.menu.items[1].id == "Open"

        @test fieldnames(JSONTypes.Item) == (:id, :label)

        JSON3.@generatetypes(menu_array, :MyMod)
        json_arr = JSON3.read(menu_array, Vector{MyMod.Root})
        @test length(json_arr) == 2
        @test json_arr[1].menu.header == "SVG Viewer"
    end

    @testset "Var Names" begin
        json_str = """{"end": 1, "##invalid##": 2}"""
        JSON3.@generatetypes(json_str)
        json = JSON3.read(json_str, JSONTypes.Root)

        @test json.end == 1
        @test getproperty(json, Symbol("##invalid##")) == 2

        # on lower versions of julia, there is a warning for the user to act on
        @static if Base.VERSION >= v"1.3"
            path = mktempdir()
            file_path = joinpath(path, "struct.jl")

            JSON3.writetypes(json_str, file_path; module_name = :KeywordType)
            include(file_path)
            parsed = JSON3.read(json_str, KeywordType.Root)

            @test parsed.end == 1
            @test getproperty(parsed, Symbol("##invalid##")) == 2
        end
    end

    @testset "Duplicate Names" begin
        json_str = """
        {
            "label": {
                "type": "alert",
                "label": [
                    {
                        "type": "text",
                        "text": {
                            "content": "Open New",
                            "label": {
                                "text": "open"
                            }
                        }
                    }
                ]
            }
        }
        """
        JSON3.@generatetypes(json_str)
        json = JSON3.read(json_str, JSONTypes.Root)
        @test json.label.label[1].text.label.text == "open"
    end
end
