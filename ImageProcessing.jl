module ImageProcessing

using Plots
using Images

export load_image, normalize, denormalize, show_image

function load_image(file_path)
    # Load the image
    img = load(file_path)
    # Convert the image to a matrix of floats
    img = float32.(channelview(img))
    return img
end

function normalize(x)
    # define function for [0,1] -> [-1,+1] 
    return 2 * x .- 1
end

function denormalize(x)
    # define function for [-1,+1] -> [0,1]
    return (x .+ 1) ./ 2
end

# define function for showing the image 
function show_image(input)
    img = colorview(RGB, clamp.(denormalize(input), 0, 1))
    return plot(img)
end

end # module ImageProcessing