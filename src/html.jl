"""
    IMAGEMIME

Union of MIME image types.
Based on Pluto.PlutoRunner.imagemimes.
"""
const IMAGEMIME = Union{
    MIME"image/svg+xml",
    MIME"image/png",
    MIME"image/jpg",
    MIME"image/jpeg",
    MIME"image/bmp",
    MIME"image/gif"
}

"""
    _escape_html(s::AbstractString)

Escape HTML.
Useful for showing HTML inside code blocks, see
https://github.com/rikhuijzer/PlutoStaticHTML.jl/issues/9.
"""
function _escape_html(s::AbstractString)
    s = replace(s, '<' => "&lt;")
    s = replace(s, '>' => "&gt;")
    return s
end

function code_block(code; class="language-julia")
    if code == ""
        return ""
    end
    code = _escape_html(code)
    return """<pre><code class="$class">$code</code></pre>"""
end

function output_block(s; class="code-output")
    if s == ""
        return ""
    end
    return """<pre><code class="$class">$s</code></pre>"""
end

function _code2html(code::AbstractString, class, hide_md_code, hide_code)
    if hide_code
        return ""
    end
    if hide_md_code && startswith(code, "md\"")
        return ""
    end
    if contains(code, "# hideall")
        return ""
    end
    sep = '\n'
    lines = split(code, sep)
    filter!(!endswith("# hide"), lines)
    code = join(lines, sep)
    return code_block(code; class)
end

function _output2html(body, T::IMAGEMIME, class)
    encoded = base64encode(body)
    uri = "data:$T;base64,$encoded"
    return """<img src="$uri">"""
end

function _output2html(body, ::MIME"application/vnd.pluto.stacktrace+object", class)
    return error(body)
end

function _tr_wrap(elements::Vector)
    joined = join(elements, '\n')
    return "<tr>\n$joined\n</tr>"
end
_tr_wrap(::Array{String, 0}) = "<tr>\n<td>...</td>\n</tr>"

function _output2html(body::Dict{Symbol,Any}, ::MIME"application/vnd.pluto.table+object", class)
    rows = body[:rows]
    nms = body[:schema][:names]
    headers = _tr_wrap(["<th>$colname</th>" for colname in nms])
    contents = map(rows) do row
        # Drop index.
        row = row[2:end]
        # Unpack the type and throw away mime info.
        elements = try
            first.(only(row))
        catch
            first.(first.(row))
        end
        elements = ["<td>$e</td>" for e in elements]
        return _tr_wrap(elements)
    end
    content = join(contents, '\n')
    return """
        <table>
        $headers
        $content
        </table>
        """
end

abstract type Struct end

function symbol2type(s::Symbol)
    if s == :Tuple
        return Tuple
    elseif s == :Array
        return Array
    elseif s == :struct
        return Struct
    else
        @warn "Missing type: $s"
        return Missing
    end
end

"""
    _clean_tree(parent, element::Tuple{Any, Tuple{String, MIME}}, T)

Drop metadata.
For example, `(1, ("\"text\"", MIME type text/plain))` becomes "text".
"""
function _clean_tree(parent, element::Tuple{Any, Tuple{String, MIME}}, T)
    return first(last(element))
end

function _clean_tree(parent, element::Tuple{Any, Any}, T)
    embedded = first(last(element))
    if embedded isa String
        return embedded
    end
    struct_name = embedded[:prefix]
    elements = embedded[:elements]
    subelements = [_clean_tree(parent, e, Nothing) for e in elements]
    joined = join(subelements, ", ")
    return struct_name * '(' * joined * ')'
end

function _clean_tree(parent, elements::Tuple{Any, Tuple}, T)
    body = first(last(elements))
    T = symbol2type(body[:type])
    return _clean_tree(body, body[:elements], T)
end

function _clean_tree(parent, elements::AbstractVector, T::Type{Tuple})
    cleaned = [_clean_tree(parent, e, Nothing) for e in elements]
    joined = join(cleaned, ", ")
    return "($joined)"
end

function _clean_tree(parent, elements::AbstractVector, T::Type{Array})
    cleaned = [_clean_tree(parent, e, Nothing) for e in elements]
    joined = join(cleaned, ", ")
    return "[$joined]"
end

function _clean_tree(parent, elements::AbstractVector, T::Type{Struct})
    cleaned = [_clean_tree(parent, e, Nothing) for e in elements]
    joined = join(cleaned, ", ")
    return parent[:prefix] * '(' * joined * ')'
end

# Fallback. This shouldn't happen. Convert to string to avoid failure.
function _clean_tree(parent, elements, T)
    @warn "Couldn't convert $parent"
    return string(elements)::String
end

function _output2html(body::Dict{Symbol,Any}, ::MIME"application/vnd.pluto.tree+object", class)
    T = symbol2type(body[:type])
    cleaned = _clean_tree(body, body[:elements], T)
    return output_block(cleaned; class)
end

_output2html(body, ::MIME"text/plain", class) = output_block(body)
_output2html(body, ::MIME"text/html", class) = body
_output2html(body, T::MIME, class) = error("Unknown type: $T")

function _cell2html(cell::Cell, code_class, output_class, hide_md_code, hide_code)
    code = _code2html(cell.code, code_class, hide_md_code, hide_code)
    output = _output2html(cell.output.body, cell.output.mime, output_class)
    return """
        $code
        $output
        """
end

"""
    _append_cell!(notebook::Notebook, cell::Cell)

Add one `cell` to the end of the `notebook`.
This is based on `add_remote_cell` in Pluto's `Editor.js`.
"""
function _append_cell!(notebook::Notebook, cell::Cell)
    push!(notebook.cell_order, cell.cell_id)
    notebook.cells_dict[cell.cell_id] = cell
    return notebook
end

function _append_cell!(notebook::Notebook, cells::AbstractVector{Cell})
    foreach(c -> _append_cell!(notebook, c), cells)
    return notebook
end

function run_notebook!(notebook, session; run_async=false)
    cells = [last(e) for e in notebook.cells_dict]
    update_save_run!(session, notebook, cells; run_async)
    return nothing
end

"""
    notebook2html(
        notebook::Notebook;
        code_class="language-julia",
        output_class="code-output",
        hide_code=false,
        hide_md_code=true,
        append_build_context=false
    )

Return the code and output as HTML for `notebook`.
Assumes that the notebook has already been executed.

Keyword arguments:

- `code_class`: Code class used by CSS and/or the syntax highlighter.
- `output_class`: Output class used by CSS and/or the syntax highlighter.
- `hide_code`: Hide code. Can be useful when readers are not interested in code at all.
- `hide_md_code`: Hide code for Markdown blocks. Enabled by default.
- `append_build_context`: Append build context to the end of each output.
    This is not executed via Pluto.jl's evaluation to avoid having to add extra dependencies to existing notebooks.
    Instead, this reads the manifest from the notebook file.
"""
function notebook2html(
        notebook::Notebook;
        code_class="language-julia",
        output_class="code-output",
        hide_code=false,
        hide_md_code=true,
        append_build_context=false
    )
    order = notebook.cell_order
    outputs = map(order) do cell_uuid
        cell = notebook.cells_dict[cell_uuid]
        _cell2html(cell, code_class, output_class, hide_md_code, hide_code)
    end
    html = join(outputs, '\n')
    if append_build_context
        html = html * _context(notebook)
    end
    return html
end

function _load_notebook(path::AbstractString)
    tmp_path = tempname()
    # Avoid Pluto making changes to the original notebook.
    cp(path, tmp_path)
    notebook = load_notebook_nobackup(tmp_path)
    return notebook
end

"""
    notebook2html(path::AbstractString; session=ServerSession(), append_cells=Cell[], kwargs...)

Run the Pluto notebook at `path` and return the code and output as HTML.
The `kwargs` are passed to `notebook2html(notebook::Notebook, kwargs...)`.

Keyword arguments:

- `append_cells`: Specify one or more `Pluto.Cell`s to be appended at the end of the notebook.
    Be careful when adding new packages via this method because it may disable Pluto.jl's built-in package management.
"""
function notebook2html(path::AbstractString; session=ServerSession(), append_cells=Cell[], kwargs...)
    notebook = _load_notebook(path)
    PlutoStaticHTML._append_cell!(notebook, append_cells)
    run_notebook!(notebook, session; run_async=false)
    html = notebook2html(notebook; kwargs...)
    return html
end
