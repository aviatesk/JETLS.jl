using JETLS: JS, JL

function parsedstream(s::AbstractString, rule::Symbol=:all)
    stream = JS.ParseStream(s)
    JS.parse!(stream; rule)
    return stream
end

jsparse(s::AbstractString) = jsparse(parsedstream(s))
function jsparse(parsed_stream::JS.ParseStream; filename::AbstractString=@__FILE__)
    JS.build_tree(JS.SyntaxNode, parsed_stream; filename)
end

jlparse(s::AbstractString) = jlparse(parsedstream(s))
function jlparse(parsed_stream::JS.ParseStream; filename::AbstractString=@__FILE__)
    JS.build_tree(JL.SyntaxTree, parsed_stream; filename)
end
