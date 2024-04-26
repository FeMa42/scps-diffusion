module DenoisingDiffusion

import Base.show, Base.eltype

using Flux
import Flux._big_show, Flux._show_children
using ProgressMeter
using Printf
using BSON
using Random
import NNlib: batched_mul

include("GaussianDiffusion.jl")
include("train.jl")

export GaussianDiffusion
export linear_beta_schedule, cosine_beta_schedule
export q_sample, q_posterior_mean_variance
export p_sample # , p_sample_loop, p_sample_loop_all, predict_start_from_noise

include("models/embed.jl")
export SinusoidalPositionEmbedding
include("models/ConditionalChain.jl")
export ConditionalChain 


end # module
