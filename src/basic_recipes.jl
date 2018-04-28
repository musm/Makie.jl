function default_theme(scene, ::Type{Contour})
    Theme(;
        default_theme(scene)...,
        colormap = theme(scene, :colormap),
        colorrange = nothing,
        levels = 5,
        linewidth = 1.0,
        fillrange = false,
    )
end

to_vector(x::AbstractVector, len, T) = convert(Vector{T}, x)
to_vector(x::ClosedInterval, len, T) = linspace(T.(extrema(x))..., len)

function resample(x::AbstractVector, len)
    length(x) == len && return x
    interpolated_getindex.((x,), linspace(0.0, 1.0, len))
end

function resampled_colors(attributes, levels)
    cols = if haskey(attributes, :color)
        c = attribute_convert(value(attributes[:color]), key"color"())
        repeated(c, levels)
    else
        c = attribute_convert(value(attributes[:colormap]), key"colormap"())
        resample(c, levels)
    end
end

function contourlines(::Type{Contour}, contours, cols)
    result = Point2f0[]
    colors = RGBA{Float32}[]
    for (color, c) in zip(cols, Main.Contour.levels(contours))
        for elem in Main.Contour.lines(c)
            append!(result, elem.vertices)
            push!(result, Point2f0(NaN32))
            append!(colors, fill(color, length(elem.vertices) + 1))
        end
    end
    result, colors
end
function contourlines(::Type{Contour3d}, contours, cols)
    result = Point3f0[]
    colors = RGBA{Float32}[]
    for (color, c) in zip(cols, Main.Contour.levels(contours))
        for elem in Main.Contour.lines(c)
            for p in elem.vertices
                push!(result, Point3f0(p[1], p[2], c.level))
            end
            push!(result, Point3f0(NaN32))
            append!(colors, fill(color, length(elem.vertices) + 1))
        end
    end
    result, colors
end
plot!(scene::Scenelike, t::Type{Contour}, attributes::Attributes, args...) = contourplot(scene, t, attributes, args...)
plot!(scene::Scenelike, t::Type{Contour3d}, attributes::Attributes, args...) = contourplot(scene, t, attributes, args...)

to_levels(x::AbstractVector{<: Number}, cnorm) = x
function to_levels(x::Integer, cnorm)
    linspace(cnorm..., x)
end

function contourplot(scene::Scenelike, ::Type{Contour}, attributes::Attributes, x, y, z, vol)
    attributes, rest = merged_get!(:contour, scene, attributes) do
        default_theme(scene, Contour)
    end
    replace_nothing!(attributes, :alpha) do
        Signal(0.5)
    end
    xyz_volume = convert_arguments(Contour, x, y, z, vol)
    x, y, z, volume = node.((:x, :y, :z, :volume), xyz_volume)
    colorrange = replace_nothing!(attributes, :colorrange) do
        map(x-> Vec2f0(extrema(x)), volume)
    end
    @extract attributes (colormap, levels, linewidth, alpha)
    cmap = map(colormap, levels, linewidth, alpha, colorrange) do _cmap, l, lw, alpha, cnorm
        levels = to_levels(l, cnorm)
        N = length(levels) * 50
        iso_eps = 0.01 # TODO calculate this
        cmap = attribute_convert(_cmap, key"colormap"())
        # resample colormap and make the empty area between iso surfaces transparent
        map(1:N) do i
            i01 = (i-1) / (N - 1)
            c = interpolated_getindex(cmap, i01)
            isoval = cnorm[1] + (i01 * (cnorm[2] - cnorm[1]))
            line = reduce(false, levels) do v0, level
                v0 || (abs(level - isoval) <= iso_eps)
            end
            RGBAf0(color(c), line ? alpha : 0.0)
        end
    end
    c = Combined{:Contour}(scene, attributes, x, y, z, volume)
    volume!(c, x, y, z, volume, colormap = cmap, colorrange = colorrange, algorithm = :iso)
    plot!(scene, c, rest)
end

function contourplot(scene::Scenelike, ::Type{T}, attributes::Attributes, args...) where T
    attributes, rest = merged_get!(:contour, scene, attributes) do
        default_theme(scene, Contour)
    end
    x, y, z = convert_arguments(Contour, node.((:x, :y, :z), args)...)
    contourplot = Combined{:Contour}(scene, attributes, x, y, z)
    calculate_values!(contourplot, Contour, attributes, (x, y, z))
    t = eltype(z)
    if value(attributes[:fillrange])
        attributes[:interpolate] = true
        if T == Contour
            # TODO normalize linewidth for heatmap
            attributes[:linewidth] = map(x-> x ./ 10f0, attributes[:linewidth])
            heatmap!(contourplot, attributes, x, y, z)
        else
            surface!(contourplot, attributes, x, y, z)
        end
    else
        levels = round(Int, value(attributes[:levels]))
        contours = Main.Contour.contours(to_vector(x, size(z, 1), t), to_vector(y, size(z, 2), t), z, levels)
        cols = resampled_colors(attributes, levels)
        result, colors = contourlines(T, contours, cols)
        attributes[:color] = colors
        lines!(contourplot, merge(attributes, rest), result)
    end
    plot!(scene, contourplot, rest)
end


function plot!(scene::Scenelike, ::Type{Poly}, attributes::Attributes, args...)
    attributes, rest = merged_get!(:poly, scene, attributes) do
        Theme(;
            default_theme(scene)...,
            linecolor = RGBAf0(0,0,0,0),
            linewidth = 0.0,
            linestyle = nothing
        )
    end

    positions_n = to_node(convert_arguments(Poly, args...)[1])
    bigmesh = map(positions_n) do p
        polys = GeometryTypes.split_intersections(p)
        merge(GLPlainMesh.(polys))
    end
    poly = Combined{:Poly}(scene, attributes, positions_n)
    mesh!(poly, bigmesh, color = attributes[:color])
    outline = map(positions_n) do p
        push!(copy(p), p[1]) # close path
    end
    lines!(
        poly, outline,
        color = attributes[:linecolor], linestyle = attributes[:linestyle],
        linewidth = attributes[:linewidth],
        visible = map(x-> x > 0.0, attributes[:linewidth])
    )
    return plot!(scene, poly, rest)
end
# function poly(scene::makie, points::AbstractVector{Point2f0}, attributes::Dict)
#     attributes[:positions] = points
#     _poly(scene, attributes)
# end
# function poly(scene::makie, x::AbstractVector{<: Number}, y::AbstractVector{<: Number}, attributes::Dict)
#     attributes[:x] = x
#     attributes[:y] = y
#     _poly(scene, attributes)
# end
function plot!(scene::Scenelike, ::Type{Poly}, attributes::Attributes, x::AbstractVector{T}) where T <: Union{Circle, Rectangle}
    position = map(node(:positions, x)) do rects
        map(rects) do rect
            minimum(rect) .+ (widths(rect) ./ 2f0)
        end
    end
    attributes[:markersize] = map(node(:markersize, x)) do rects
        widths.(rects)
    end
    attributes[:marker] = T
    poly = Combined{:Poly}(scene, attributes, x)
    plot!(poly, Scatter, attributes, position)
    poly
end

function layout_text(
        string::AbstractString, startpos::VecTypes{N, T}, textsize::Number,
        font, align, rotation, model
    ) where {N, T}

    offset_vec = attribute_convert(align, key"align"())
    ft_font = attribute_convert(font, key"font"())
    rscale = attribute_convert(textsize, key"textsize"())
    rot = attribute_convert(rotation, key"rotation"())

    atlas = GLVisualize.get_texture_atlas()
    mpos = model * Vec4f0(to_ndim(Vec3f0, startpos, 0f0)..., 1f0)
    pos = to_ndim(Point{N, Float32}, mpos, 0)

    positions2d = GLVisualize.calc_position(string, Point2f0(0), rscale, ft_font, atlas)
    aoffset = align_offset(Point2f0(0), positions2d[end], atlas, rscale, ft_font, offset_vec)
    aoffsetn = to_ndim(Point{N, Float32}, aoffset, 0f0)
    scales = Vec2f0[GLVisualize.glyph_scale!(atlas, c, ft_font, rscale) for c = string]
    positions = map(positions2d) do p
        pn = qmul(rot, to_ndim(Point{N, Float32}, p, 0f0) .+ aoffsetn)
        pn .+ (pos)
    end
    positions, scales
end


function plot!(scene::Scenelike, ::Type{Annotations}, attributes::Attributes, text::AbstractVector{String}, positions::AbstractVector{<: VecTypes{N, T}}) where {N, T}
    attributes, rest = merged_get!(:annotations, scene, attributes) do
        default_theme(scene, Text)
    end
    calculate_values!(scene, Text, attributes, text)
    t_args = (to_node(text), to_node(positions))
    annotations = Combined{:Annotations}(scene, attributes, t_args...)
    sargs = (
        attributes[:model], attributes[:font],
        t_args...,
        getindex.(attributes, (:color, :textsize, :align, :rotation))...,
    )
    tp = map(sargs...) do model, font, args...
        if length(args[1]) != length(args[2])
            error("For each text annotation, there needs to be one position. Found: $(length(t)) strings and $(length(p)) positions")
        end
        atlas = GLVisualize.get_texture_atlas()
        io = IOBuffer(); combinedpos = Point{N, Float32}[]; colors = RGBAf0[]
        scales = Vec2f0[]; fonts = Font[]; rotations = Vec4f0[]; alignments = Vec2f0[]
        broadcast_foreach(1:length(args[1]), args...) do idx, text, startpos, color, tsize, alignment, rotation
            # the fact, that Font == Vector{FT_FreeType.Font} is pretty annoying for broadcasting.
            # TODO have a better Font type!
            f = attribute_convert(font, key"font"())
            f = isa(f, Font) ? f : f[idx]
            c = attribute_convert(color, key"color"())
            rot = attribute_convert(rotation, key"rotation"())
            ali = attribute_convert(alignment, key"align"())
            pos, s = layout_text(text, startpos, tsize, f, alignment, rot, model)
            print(io, text)
            n = length(pos)
            append!(combinedpos, pos)
            append!(scales, s)
            append!(colors, repeated(c, n))
            append!(fonts,  repeated(f, n))
            append!(rotations, repeated(rot, n))
            append!(alignments, repeated(ali, n))
        end
        (String(take!(io)), combinedpos, colors, scales, fonts, rotations, rotations)
    end
    t_attributes = merge(attributes, rest)
    t_attributes[:position] = map(x-> x[2], tp)
    t_attributes[:color] = map(x-> x[3], tp)
    t_attributes[:textsize] = map(x-> x[4], tp)
    t_attributes[:font] = map(x-> x[5], tp)
    t_attributes[:rotation] = map(x-> x[6], tp)
    t_attributes[:align] = map(x-> x[7], tp)
    t_attributes[:model] = eye(Mat4f0)
    plot!(annotations, Text, t_attributes, map(x->x[1], tp))
    annotations
end



function plot!(scene::Scenelike, attributes::Attributes, matrix::AbstractMatrix{<: AbstractFloat})
    attributes, rest = merged_get!(:series, scene, attributes) do
        Theme(
            seriescolors = :Set1,
            seriestype = :lines
        )
    end
    A = node(:series, matrix)
    sub = Combined{:Series}(scene, attributes, A)
    colors = map_once(attributes[:seriescolors], A) do colors, A
        cmap = attribute_convert(colors, key"colormap"())
        if size(A, 2) > length(cmap)
            warn("Colormap doesn't have enough distinctive values. Please consider using another value for seriescolors")
            cmap = interpolated_getindex.((cmap,), linspace(0, 1, M))
        end
        cmap
    end
    plots = map_once(A, attributes[:seriestype]) do A, stype
        empty!(sub.plots)
        N, M = size(A)
        map(1:M) do i
            c = map(getindex, colors, Node(i))
            attributes = Theme(color = c)
            subsub = Combined{:LineScatter}(sub, attributes, A)
            if stype in (:lines, :scatter_lines)
                lines!(subsub, attributes, 1:N, A[:, i])
            end
            if stype in (:scatter, :scatter_lines)
                scatter!(subsub, attributes, 1:N, A[:, i])
            end
            subsub
        end
    end
    labels = get(attributes, :labels) do
        map(i-> "y $i", 1:size(matrix, 2))
    end
    l = legend(scene, plots[], labels, rest)
    plot!(scene, sub, rest)
end




arrow_head(::Type{<: Point{3}}) = Pyramid(Point3f0(0, 0, -0.5), 1f0, 1f0)
arrow_head(::Type{<: Point{2}}) = '▲'

scatterfun(::Type{<: Point{2}}) = scatter!
scatterfun(::Type{<: Point{3}}) = meshscatter!

function arrows(
        scene, points::AbstractVector{T}, directions::AbstractVector{<: VecTypes};
        kw_args...
    ) where T <: VecTypes
    attributes, rest = merged_get!(:arrows, scene, Attributes(kw_args)) do
        color = :black
        Theme(
            arrowhead = Pyramid(Point3f0(0, 0, -0.5), 1f0, 1f0),
            arrowtail = nothing,
            linecolor = color,
            arrowcolor = color,
            linewidth = 1,
            arrowsize = 0.3,
            linestyle = nothing,
            scale = Vec3f0(1),
            normalize = false,
            lengthscale = 1.0f0
        )
    end
    points_n = node(:arrow_origins, points)
    directions_n = node(:arrow_dir, directions)

    arrows = Combined{:Arrows}(scene, attributes, points_n, directions_n)
    headstart = map(points_n, directions_n, attributes[:lengthscale]) do points, directions, s
        map(points, directions) do p1, dir
            dir = attributes[:normalize][] ? StaticArrays.normalize(dir) : dir
            p1 => p1 .+ (dir .* Float32(s))
        end
    end

    ls = linesegments!(
        arrows,
        map(reinterpret, Signal(Point3f0), headstart),
        color = arrows[:linecolor],
        linewidth = arrows[:linewidth],
        linestyle = arrows[:linestyle]
    )
    heads = map(x-> last.(x), headstart)
    scatterfun(T)(
        arrows,
        heads, marker = arrows[:arrowhead],
         markersize = attributes[:arrowsize],
        color = attributes[:arrowcolor],
        rotations = directions_n
    )
    plot!(scene, arrows, rest)
end


function wireframe(scene::Scenelike, x::AbstractVector, y::AbstractVector, z::AbstractMatrix, attributes::Dict)
    wireframe(ngrid(x, y)..., z, attributes)
end

function wireframe!(scene::Scenelike, x::AbstractMatrix, y::AbstractMatrix, z::AbstractMatrix, attributes::Dict)
    if (length(x) != length(y)) || (length(y) != length(z))
        error("x, y and z must have the same length. Found: $(length(x)), $(length(y)), $(length(z))")
    end
    points = lift_node(to_node(x), to_node(y), to_node(z)) do x, y, z
        Point3f0.(vec(x), vec(y), vec(z))
    end
    NF = (length(z) * 4) - ((size(z, 1) + size(z, 2)) * 2)
    faces = Vector{Int}(NF)
    idx = (i, j) -> sub2ind(size(z), i, j)
    li = 1
    for i = 1:size(z, 1), j = 1:size(z, 2)
        if i < size(z, 1)
            faces[li] = idx(i, j);
            faces[li + 1] = idx(i + 1, j)
            li += 2
        end
        if j < size(z, 2)
            faces[li] = idx(i, j)
            faces[li + 1] = idx(i, j + 1)
            li += 2
        end
    end
    linesegment!(scene, view(points, faces), attributes)
end


function wireframe(scene::Scenelike, mesh, attributes::Dict)
    mesh = to_node(mesh, x-> to_mesh(scene, x))
    points = lift_node(mesh) do g
        decompose(Point3f0, g) # get the point representation of the geometry
    end
    indices = lift_node(mesh) do g
        idx = decompose(Face{2, GLIndex}, g) # get the point representation of the geometry
    end
    linesegment(scene, view(points, indices), attributes)
end


function sphere_streamline(linebuffer, ∇ˢf, pt, h = 0.01f0, n = 5)
    push!(linebuffer, pt)
    df = normalize(∇ˢf(pt[1], pt[2], pt[3]))
    push!(linebuffer, normalize(pt .+ h*df))
    for k=2:n
        cur_pt = last(linebuffer)
        push!(linebuffer, cur_pt)
        df = normalize(∇ˢf(cur_pt...))
        push!(linebuffer, normalize(cur_pt .+ h*df))
    end
    return
end


function streamlines!(
        scene::Scenelike,
        origins::AbstractVector{T},
        directions;
        kw_args...
    ) where T
    attributes, rest = merged_get!(:streamlines, scene, kw_args) do
        Theme(
            h = 0.01f0,
            n = 5,
            color = :black,
            linewidth = 1
        )
    end
    dirs_n, pts_n = node(:dirs, directions), node(:origins, origins)
    linebuffer = T[]
    sub = Combined{:Streamlines}(
        scene,
        attributes,
        pts_n, dirs_n
    )
    lines = map(dirs_n, pts_n, sub[:h], sub[:n]) do ∇ˢf, origins, h, n
        empty!(linebuffer)
        for point in origins
            sphere_streamline(linebuffer, ∇ˢf, point, h, n)
        end
        linebuffer
    end
    linesegments!(sub, lines, color = sub[:color], linewidth = sub[:linewidth])
    plot!(scene, sub, rest)
end

function mergekeys(keys::NTuple{N, Symbol}, target::Attributes, source::Attributes) where N
    result = copy(target)
    for key in keys
        get!(result, key, source[key])
    end
    result
end


function volumeslices(scene, x, y, z, volume; kw_args...)
    attributes, rest = merged_get!(:volumeslices, scene, kw_args) do
        Theme(
            colormap = theme(scene, :colormap),
            colorrange = nothing,
            alpha = 0.1,
            contour = Attributes(),
            heatmap = Attributes(),
        )
    end
    xyz_volume = convert_arguments(Contour, x, y, z, volume)
    x, y, z, volume = node.((:x, :y, :z, :volume), xyz_volume)
    replace_nothing!(attributes, :colorrange) do
        map(extrema, volume)
    end
    vs = Combined{:VolumeSlices}(scene, attributes, x, y, z, volume)
    keys = (:colormap, :alpha, :colorrange)
    cattributes = mergekeys(keys, attributes[:contour][], attributes)
    plot!(vs, Contour, cattributes, x, y, z, volume)
    planes = (:xy, :xz, :yz)
    hattributes = mergekeys(keys, attributes[:heatmap][], attributes)
    sliders = map(zip(planes, (x, y, z))) do plane_r
        plane, r = plane_r
        idx = node(plane, Signal(1))
        attributes[plane] = idx
        hmap = heatmap!(vs, hattributes, x, y, zeros(length(x[]), length(y[])))
        foreach(idx) do i
            transform!(hmap, (plane, r[][i]))
            indices = ntuple(Val{3}) do j
                planes[j] == plane ? i : (:)
            end
            hmap[3][] = view(volume[], indices...)
        end
        idx
    end
    plot!(scene, vs, rest)
end