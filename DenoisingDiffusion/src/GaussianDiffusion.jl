"""
    GaussianDiffusion(V::DataType, βs, data_shape, denoise_fn)

A Gaussian Diffusion Probalistic Model (DDPM) as introduced in "Denoising Diffusion Probabilistic Models" by Ho et. al (https://arxiv.org/abs/2006.11239).
"""
struct GaussianDiffusion{V<:AbstractVector}
    num_timesteps::Int
    data_shape::NTuple
    denoise_fn

    βs::V
    αs::V
    α_cumprods::V
    α_cumprod_prevs::V

    sqrt_α_cumprods::V
    sqrt_one_minus_α_cumprods::V
    sqrt_recip_α_cumprods::V
    sqrt_recip_α_cumprods_minus_one::V
    posterior_variance::V
    posterior_log_variance_clipped::V
    posterior_mean_coef1::V
    posterior_mean_coef2::V
end

eltype(::Type{<:GaussianDiffusion{V}}) where {V} = V

Flux.@functor GaussianDiffusion
Flux.trainable(g::GaussianDiffusion) = (; g.denoise_fn)

function Base.show(io::IO, diffusion::GaussianDiffusion)
    V = typeof(diffusion).parameters[1]
    print(io, "GaussianDiffusion{$V}(")
    print(io, "num_timesteps=$(diffusion.num_timesteps)")
    print(io, ", data_shape=$(diffusion.data_shape)")
    print(io, ", denoise_fn=$(diffusion.denoise_fn)")
    num_buffers = 12
    buffers_size = Base.format_bytes(Base.summarysize(diffusion.βs) * num_buffers)
    print(io, ", buffers_size=$buffers_size")
    print(io, ")")
end

function GaussianDiffusion(V::DataType, βs::AbstractVector, data_shape::NTuple, denoise_fn)
    αs = 1 .- βs
    α_cumprods = cumprod(αs)
    α_cumprod_prevs = [1, (α_cumprods[1:end-1])...]

    sqrt_α_cumprods = sqrt.(α_cumprods)
    sqrt_one_minus_α_cumprods = sqrt.(1 .- α_cumprods)
    sqrt_recip_α_cumprods = 1 ./ sqrt.(α_cumprods)
    sqrt_recip_α_cumprods_minus_one = sqrt.(1 ./ α_cumprods .- 1)

    posterior_variance = βs .* (1 .- α_cumprod_prevs) ./ (1 .- α_cumprods)
    posterior_log_variance_clipped = log.(max.(posterior_variance, 1e-20))

    posterior_mean_coef1 = βs .* sqrt.(α_cumprod_prevs) ./ (1 .- α_cumprods)
    posterior_mean_coef2 = (1 .- α_cumprod_prevs) .* sqrt.(αs) ./ (1 .- α_cumprods)

    GaussianDiffusion{V}(
        length(βs),
        data_shape,
        denoise_fn,
        βs,
        αs,
        α_cumprods,
        α_cumprod_prevs,
        sqrt_α_cumprods,
        sqrt_one_minus_α_cumprods,
        sqrt_recip_α_cumprods,
        sqrt_recip_α_cumprods_minus_one,
        posterior_variance,
        posterior_log_variance_clipped,
        posterior_mean_coef1,
        posterior_mean_coef2
    )
end

"""
    linear_beta_schedule(num_timesteps, β_start=0.0001f0, β_end=0.02f0)
"""
function linear_beta_schedule(num_timesteps::Int, β_start=0.0001f0, β_end=0.02f0)
    scale = convert(typeof(β_start), 1000 / num_timesteps)
    β_start *= scale
    β_end *= scale
    range(β_start, β_end; length=num_timesteps)
end

"""
    cosine_beta_schedule(num_timesteps, s=0.008)

Cosine schedule as proposed in "Improved Denoising Diffusion Probabilistic Models" by Nichol, Dhariwal (https://arxiv.org/abs/2102.09672)
"""
function cosine_beta_schedule(num_timesteps::Int, s=0.008)
    t = range(0, num_timesteps; length=num_timesteps + 1)
    α_cumprods = (cos.((t / num_timesteps .+ s) / (1 + s) * π / 2)) .^ 2
    α_cumprods = α_cumprods / α_cumprods[1]
    βs = 1 .- α_cumprods[2:end] ./ α_cumprods[1:(end-1)]
    clamp!(βs, 0, 0.999)
    βs
end

## extract input[idxs] and reshape for broadcasting across a batch.
function _extract(input, idxs::AbstractVector{Int}, shape::NTuple)
    reshape(input[idxs], (repeat([1], length(shape) - 1)..., :))
end

"""
    q_sample(diffusion, x_start, timesteps, noise)
    q_sample(diffusion, x_start, timesteps; to_device=cpu)

The forward process ``q(x_t | x_0)``. Diffuse the data for a given number of diffusion steps.
"""
function q_sample(
    diffusion::GaussianDiffusion, 
    x_start::AbstractArray, 
    timesteps::AbstractVector{Int}, 
    noise::AbstractArray
    )
    coeff1 = _extract(diffusion.sqrt_α_cumprods, timesteps, size(x_start))
    coeff2 = _extract(diffusion.sqrt_one_minus_α_cumprods, timesteps, size(x_start))
    coeff1 .* x_start + coeff2 .* noise
end

function q_sample(
    diffusion::GaussianDiffusion,
    x_start::AbstractArray, 
    timesteps::AbstractVector{Int}
    ;to_device=cpu
    )
    T = eltype(eltype(diffusion))
    noise = randn(T, size(x_start)) |> to_device
    timesteps = timesteps |> to_device
    q_sample(diffusion, x_start, timesteps, noise)
end

function q_sample(
    diffusion::GaussianDiffusion,
    x_start::AbstractArray{T,N},
    timestep::Int; to_device=cpu
    ) where {T,N}
    timesteps = fill(timestep, size(x_start, N)) |> to_device
    q_sample(diffusion, x_start, timesteps; to_device=to_device)
end

"""
    q_posterior_mean_variance(diffusion, x_start, x_t, timesteps)

Compute the mean and variance for the ``q_{posterior}(x_{t-1} | x_t, x_0) = q(x_t | x_{t-1}, x_0) q(x_{t-1} | x_0) / q(x_t | x_0)``
where `x_0 = x_start`. 
The ``q_{posterior}`` is a Bayesian estimate of the reverse process ``p(x_{t-1} | x_{t})`` where ``x_0`` is known.
"""
function q_posterior_mean_variance(diffusion::GaussianDiffusion, x_start::AbstractArray, x_t::AbstractArray, timesteps::AbstractVector{Int})
    coeff1 = _extract(diffusion.posterior_mean_coef1, timesteps, size(x_t))
    coeff2 = _extract(diffusion.posterior_mean_coef2, timesteps, size(x_t))
    posterior_mean = coeff1 .* x_start + coeff2 .* x_t
    posterior_variance = _extract(diffusion.posterior_variance, timesteps, size(x_t))
    posterior_mean, posterior_variance
end

"""
    predict_start_from_noise(diffusion, x_t, timesteps, noise)

Predict an estimate for the ``x_0`` based on the forward process ``q(x_t | x_0)``.
"""
function predict_start_from_noise(diffusion::GaussianDiffusion, x_t::AbstractArray, timesteps::AbstractVector{Int}, noise::AbstractArray)
    coeff1 = _extract(diffusion.sqrt_recip_α_cumprods, timesteps, size(x_t))
    coeff2 = _extract(diffusion.sqrt_recip_α_cumprods_minus_one, timesteps, size(x_t))
    coeff1 .* x_t - coeff2 .* noise
end

function denoise(diffusion::GaussianDiffusion, x::AbstractArray, timesteps::AbstractVector{Int})
    noise = diffusion.denoise_fn(x, timesteps)
    x_start = predict_start_from_noise(diffusion, x, timesteps, noise)
    x_start, noise
end

"""
    p_sample(diffusion, x, timesteps, noise; 
        clip_denoised=true, add_noise=true)

The reverse process ``p(x_{t-1} | x_t, t)``. Denoise the data by one timestep.
"""
function p_sample(
    diffusion::GaussianDiffusion, x::AbstractArray, timesteps::AbstractVector{Int}, noise::AbstractArray;
    clip_denoised::Bool=true, add_noise::Bool=true
    )
    x_start, pred_noise = denoise(diffusion, x, timesteps)
    if clip_denoised
        clamp!(x_start, -1, 1)
    end
    posterior_mean, posterior_variance = q_posterior_mean_variance(diffusion, x_start, x, timesteps)
    x_prev = posterior_mean
    if add_noise
        x_prev += sqrt.(posterior_variance) .* noise
    end
    x_prev, x_start
end



