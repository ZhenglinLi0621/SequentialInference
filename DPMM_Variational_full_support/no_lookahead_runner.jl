#Tejas Kulkarni - tejask@mit.edu
# DPMM with SMC
#Julia PATH: 
#	/Users/tejas/Documents/julia/julia


using Distributions
using Debug
using PyCall
using Base.Collections
using MATLAB
using NumericExtensions
require("dataset.jl")
using NumericExtensions

@pyimport pylab
@pyimport sklearn.metrics as metrics

type node
	support
	weight
	depth
	time
	prev_c_aggregate
end


@debug begin 

############# HELPER FUNCTIONS and DATASTRUCTURES #################
myappend{T}(v::Vector{T}, x::T) = [v..., x] #Appending to arrays


const ENUMERATION = 0

#const NUM_PARTICLES = 1
#LOOKAHEAD_DELTA = 10#10
#const INTEGRAL_PATHS = 2#2


WORDS_PER_DOC = 100
NUM_DOCS = 1700
NUM_TOPICS = NaN
V = NaN
state = Dict()
particles = Dict()
hyperparameters = Dict()
hyperparameters["eta"]=0.5;hyperparameters["a"]=1;
const _DEBUG = 0
data = Dict()

#srand(1)


#################### DATA LOADER AND PLOTTING ##################################
const COLORS =[[rand(),rand(),rand()] for i =1:50]

function plotPoints(data,fname)
	for i=1:NUM_POINTS
		pylab.plot(data[i][1],data[i][2], "o", color=COLORS[data[i]["c"]])
	end
	pylab.savefig(string(fname,".png"))
end

function plotPointsfromChain(time,)
	ariArr = []
	pylab.clf()
	for N=1:length(particles[time])
		"""for i=1:time
			pylab.plot(data[i][1],data[i][2], "o", color=COLORS[particles[time][N]["hidden_state"]["c_aggregate"][i]])
		end
		pylab.savefig(string("time:", time, " PARTICLE_",N,"_",".png"))"""

		true_clusters = data["c_aggregate"][1:time]
		inferred_clusters = particles[time][N]["hidden_state"]["c_aggregate"]
		ariArr = myappend(ariArr, metrics.adjusted_rand_score(inferred_clusters, true_clusters))
		#println("------")
		#println("TRUE:", true_clusters)
		#println("INFR:", inferred_clusters)
		#println("------")
	end
	if length(ARGS) == 0
		println("time:", time," Maximum ARI: ", max(ariArr))
	end
	#return max(ariArr)
end



function loadObservations()
	data = Dict()
	theta, pi, NUM_TOPICS, V = dataset1()

	topics = []#[1,1,1,1,2,2,2,1,1,1]

	data["c_aggregate"] = int(zeros(NUM_DOCS))
	
	for i = 1:NUM_DOCS
		data[i] = Dict() #Create doc
		if length(topics) == 0
			topic = rand(Multinomial(1,pi)); topic = findin(topic, 1)[1]
		else
			topic = topics[i]
		end
		#data[i]["topic"] = topic
		data["c_aggregate"][i] = topic
		for j = 1:WORDS_PER_DOC
			data[i][j] = rand(Multinomial(1, theta[topic])); data[i][j] = findin(data[i][j], 1)[1] 
		end
	end

	return data
end



#################### MAIN FUNCTION DEFINITIONS ####################
function normalizeWeights(time)
	norm_arr = zeros(length(particles[time]))
	for i = 1:length(particles[time])
		norm_arr[i] = particles[time][i]["weight"]
	end
	normalizing_constant = logsumexp(norm_arr)

	for i = 1:length(particles[time])
		particles[time][i]["weight"]-=normalizing_constant
		particles[time][i]["weight"] = exp(particles[time][i]["weight"])
	end
end


## devised by Fearnhead and Clifford (2003)
function FC_resample(time)
	weight_vector = [s["weight"] for s in values(particles[time])]
	weight_vector = float64(weight_vector)
	particles_new_indx = int(zeros(length(particles[time])))
	particles_temporary = copy(particles[time])

	particles[time] = Dict() ##?? 

	for i = 1:NUM_PARTICLES
		if particles_temporary[i]["weight"] < 1/50
			sample_arr = rand(Multinomial(1,weight_vector))
			particles_new_indx[i] = findin(sample_arr, 1)[1]
			particles[time][i] = particles_temporary[particles_new_indx[i]]
			particles[time][i]["weight"] = 1/50
		else
			particles[time][i] = particles_temporary[i]
		end
	end
end	



function resample(time)
	weight_vector = [s["weight"] for s in values(particles[time])]
	weight_vector = float64(weight_vector)
	particles_new_indx = int(zeros(length(particles[time])))
	particles_temporary = copy(particles[time])
	
	particles[time] = Dict() ##?? 

	for i = 1:NUM_PARTICLES
		sample_arr = rand(Multinomial(1,weight_vector))
		particles_new_indx[i] = findin(sample_arr, 1)[1]
		particles[time][i] = particles_temporary[particles_new_indx[i]]
		#particles[time][i]["weight"] = 1/NUM_PARTICLES
	end
end	


function get_empirical_mean(y)
	return sum(y)/length(y)
end

function get_empirical_variance(y, empirical_mean)
	diff = (y - empirical_mean)
	diff = diff .* diff
	return sum(diff)/length(y)
end

function get_pts_in_cluster(clusters,cid) #number of cid's in clusters
	indices = findin(clusters,cid)
	return length(indices), indices
end



function get_joint_crp_probability(cid, cid_cardinality, indices, alpha)
	numerator = 0
	denominator = 0
	for i=1:cid_cardinality-1
		numerator += log(i)
		denominator += log(alpha + i - 1)
	end
	denominator += log(alpha + cid_cardinality - 1)

	ret = log(alpha)+numerator-denominator

	return ret
end




## deleting ancestors as do not need them now
function recycle(time)
	if time >= 3
		delete!(particles,time-2)
	end
end



function sample_cid(z_posterior_array_probability, z_posterior_array_cid)
	normalizing_constant = logsumexp(z_posterior_array_probability)
	z_posterior_array_probability -= normalizing_constant
	z_posterior_array_probability = exp(z_posterior_array_probability)

	#println(z_posterior_array_probability)
	sample_arr = rand(Multinomial(1,z_posterior_array_probability))
	indx = findin(sample_arr, 1)[1]
	cid = z_posterior_array_cid[indx]
	weight = z_posterior_array_probability[indx]

	return weight, cid
end





function pickNewChildren(current, z_posterior_array_probability, z_posterior_array_cid, PATH_QUEUE, PCNT)
	# Now choose 'p' children and add to queue
	time = current.time
	DEPTH = current.depth

	if ENUMERATION == 1
		normalizing_constant = sum(z_posterior_array_probability)
		z_posterior_array_probability /= normalizing_constant

		for ind=1:length(z_posterior_array_cid)
			child_support = unique(myappend(current.support, z_posterior_array_cid[ind]))
			child_c_aggregate = myappend(current.prev_c_aggregate, z_posterior_array_cid[ind])
			weight = z_posterior_array_probability[ind]
			child = node(unique(child_support), current.weight*weight, DEPTH+1, time+1, child_c_aggregate)
			enqueue!(PATH_QUEUE, child, PCNT)
			PCNT+=1
		end
	else 
		for p=1:INTEGRAL_PATHS
			weight, sampled_cid = sample_from_crp(z_posterior_array_probability, z_posterior_array_cid)
			if sampled_cid == max(current.support)
				child_support = myappend(current.support, sampled_cid+1)
			else
				#indx=findin(current.support, max(current.support))[1] 
				#delete!(current.support, indx)
				child_support = copy(current.support)
			end
			# Adding cluster for each data point until current time for child
			child_c_aggregate = myappend(current.prev_c_aggregate, sampled_cid)
			child = node(unique(child_support), current.weight*weight, DEPTH+1, time+1, child_c_aggregate)
			enqueue!(PATH_QUEUE, child, PCNT)
			PCNT+=1
		end
	end
	return PATH_QUEUE, PCNT
end


function generateCandidateChildren(current_support, time, prev_c_aggregate)
	z_posterior_array_probability = []
	z_posterior_array_cid = []

	for j in current_support
		current_c_aggregate = myappend(prev_c_aggregate, j)
		zj_probability = get_posterior_zj(j, current_c_aggregate, time) 

		z_posterior_array_probability = myappend(z_posterior_array_probability, zj_probability)
		z_posterior_array_cid = myappend(z_posterior_array_cid, j)
	end
	return z_posterior_array_probability, z_posterior_array_cid
end



function get_weight_lookahead(prev_support, prev_c_aggregate, time, prev_cid)
	
	if LOOKAHEAD_DELTA == 0
		return 1
	end

	PATH_QUEUE = PriorityQueue()
	PCNT = 1

	#time is already t+1
	if prev_cid == max(prev_support)
		t_1_support = unique(myappend(prev_support, prev_cid + 1))
	else
		t_1_support = copy(prev_support)
	end
	z_posterior_array_probability, z_posterior_array_cid = generateCandidateChildren(t_1_support, time, prev_c_aggregate)
	current = node(t_1_support, 1, 1, time, prev_c_aggregate)
	PATH_QUEUE, PCNT = pickNewChildren(current, z_posterior_array_probability, z_posterior_array_cid, PATH_QUEUE, PCNT)

	#Now we propagate t+2 onwards ... 
	while true
		current = dequeue!(PATH_QUEUE)
		if current.depth == LOOKAHEAD_DELTA
			#wARR = []
			#terminate and return with weight
			weight = current.weight
			#wARR = myappend(wARR, weight)
			while length(PATH_QUEUE) > 0 
				elm = dequeue!(PATH_QUEUE)
				if elm.depth != LOOKAHEAD_DELTA
					return weight
				end
				weight += elm.weight
				#wARR = myappend(wARR, elm.weight)
			end
			return weight
		end
		z_posterior_array_probability, z_posterior_array_cid = generateCandidateChildren(current.support, current.time, current.prev_c_aggregate)		
		PATH_QUEUE, PCNT = pickNewChildren(current, z_posterior_array_probability, z_posterior_array_cid, PATH_QUEUE, PCNT)
	end
end







function existing_topic_posterior_helper(time, N, eta, topic)

	state = particles[time-1][N]["hidden_state"]

	particles[time][N]["hidden_state"]["cache_topics"][topic] = Dict()
	
	#println( particles[time-1][N]["hidden_state"]["cache_topics"])

	numerator1 = 0; tmp_denominator1 = 0; #this is first side page 5 from Chong et al
	numerator2 = 0; tmp_denominator2 = 0; #this is second side page 5 from Chong et al
	denominator1 = 0;

	words_in_this_doc = collect(values(data[time]))

	for word = 1:V#for word in collect(keys(state["lambda"][topic]))
		indices = findin(words_in_this_doc, word)
		
		tmp=length(indices)
		numerator2_tmp = state["lambda"][topic][word] + tmp
		numerator2 += lgamma(numerator2_tmp)

		tmp_denominator2 += state["lambda"][topic][word]
		denominator1 += lgamma(state["lambda"][topic][word])
		particles[time][N]["hidden_state"]["cache_topics"][topic][word] = numerator2_tmp
	end

	numerator1 = lgamma(tmp_denominator2)
	denominator2 = lgamma(tmp_denominator2 + length(data[time]))

	#println("[[[[OLD]]]]:", numerator1,"  ||  ", denominator1,"  ||  ",  numerator2,"  ||  ",  denominator2)
	return (numerator1+numerator2) - (denominator1+denominator2)
end


function get_posterior_zj(cid, c_aggregate,time, N, root_support)

	eta = hyperparameters["eta"]; alpha=hyperparameters["a"]; total_pts = time
	posterior = 0

	new_cluster_flag = 0
	if cid < max(root_support)
		cid_cardinality, indices = get_pts_in_cluster(c_aggregate, cid)
		posterior += log(cid_cardinality/(total_pts + alpha)) ##prior
		#println("[PRIOR] existing", " value:", exp(posterior), " cid:", cid, "cid_cardinality:", cid_cardinality)
	else #new cluster
		cid_cardinality = 1
		new_cluster_flag = 1
		posterior += log(alpha/(total_pts + alpha)) ##prior
		#println("[PRIOR] new", " value:", exp(posterior), " cid:", cid, "cid_cardinality:", cid_cardinality)
	end

	if new_cluster_flag == 1 #new cluster
		numerator1 = lgamma(eta*V)
		denominator1 = V*lgamma(eta)
		posterior += numerator1 - denominator1 
		numerator2 = 0;
		for word = 1:V
			words_in_this_doc = collect(values(data[time]))
			indices = findin(words_in_this_doc, word)
			tmp=length(indices)
			numerator2 += lgamma(eta + tmp)
		end
		denominator2 = lgamma(eta*V + length(data[time]))
		
		posterior += numerator2		
		posterior -= denominator2

		#println("[[[[NEW]]]]:", numerator1,"  ||  ",  denominator1,"  ||  ",  numerator2,"  ||  ", denominator2)

		## create new lambda ##
		particles[time][N]["hidden_state"]["lambda"][cid] = Dict()
		for word = 1:V
			particles[time][N]["hidden_state"]["lambda"][cid][word] = hyperparameters["eta"]
		end

	else #existing cluster
		posterior += existing_topic_posterior_helper(time, N,eta,cid)
	end

	#println("[POSTERIOR] ", posterior , " v:", exp(posterior), " cid:", cid)
	#println("\n")
	return posterior

end


function path_integral(time, N)
	root_support = particles[time-1][N]["hidden_state"]["c_aggregate"]
	root_support = unique(myappend(root_support, max(root_support)+1))
	
	z_posterior_array_probability = []
	z_posterior_array_cid = []


	for j in root_support
		current_c_aggregate = myappend(particles[time-1][N]["hidden_state"]["c_aggregate"], j)
		zj_probability = get_posterior_zj(j, current_c_aggregate, time, N, root_support)

		##### lookahead. this will be support it explores further
		if time + LOOKAHEAD_DELTA <= NUM_POINTS
			zj_probability *= get_weight_lookahead(unique(current_c_aggregate),current_c_aggregate, time+1, j)
		end

		z_posterior_array_probability = myappend(z_posterior_array_probability, zj_probability)
		z_posterior_array_cid = myappend(z_posterior_array_cid, j)
	end

	weight, sampled_cid = sample_cid(z_posterior_array_probability, z_posterior_array_cid)

	return weight, sampled_cid
end


function run_sampler()
	#### particle init ####
	state=Dict()
	state["c"] = [1]
	state["c_aggregate"] = [1]
	state["lambda"] = Dict(); state["lambda"][1] = Dict();
	state["cache_topics"] = Dict();

	for word = 1:V
		state["lambda"][1][word] = hyperparameters["eta"]
	end

	time = 1
	particles[time] = Dict() #time = 0
	for i = 1:NUM_PARTICLES
		particles[time][i] = Dict() #partile_id = 0
		particles[time][i] = {"weight" => 1, "hidden_state" => state}

		#### update lambda for current document ####
		words_in_this_doc = data[1]
		for word = 1:V
			indices = findin(words_in_this_doc, word)
			tmp=length(indices)
			numerator2_tmp = state["lambda"][1][word] + tmp
			particles[time][i]["hidden_state"]["lambda"][1][word] = numerator2_tmp
		end
	end
	normalizeWeights(time)
	resample(time)


	for time = 2:NUM_DOCS

		if length(ARGS) == 0
			println("##################")
			println("time: ", time)
		end

		###### PARTICLE CREATION and EVOLUTION #######
		particles[time]=Dict()

		for N=1:NUM_PARTICLES

			if _DEBUG == 1
				println("PARTICLE:", N ," weight:", particles[time-1][N]["weight"], " support:",support)		
			end

			particles[time][N] = Dict(); 
			particles[time][N]["hidden_state"] = Dict();
			particles[time][N]["hidden_state"]["lambda"] = copy(particles[time-1][N]["hidden_state"]["lambda"])
			particles[time][N]["hidden_state"]["cache_topics"]=Dict();

			particles[time][N]["weight"], sampled_cid = path_integral(time,N)

			if length(particles[time][N]["hidden_state"]["lambda"][sampled_cid]) < 0 #existing topic / new is created in path_integral
				particles[time][N]["hidden_state"]["lambda"][sampled_cid] = particles[time][N]["hidden_state"]["cache_topics"][sampled_cid]
			end
			### Delete remaining cache_topics for other than sampled_cid later.  [[TODO]]

			particles[time][N]["hidden_state"]["c"] = sampled_cid
			particles[time][N]["hidden_state"]["c_aggregate"] = myappend(particles[time-1][N]["hidden_state"]["c_aggregate"], sampled_cid)
		end

		normalizeWeights(time)
		resample(time)
		recycle(time)
		#println(particles)
		if mod(time, 1) == 0
			plotPointsfromChain(time)
		end
	end

end


#################### MAIN RUNNER ####################
if length(ARGS) > 0
	NUM_PARTICLES = int(ARGS[1])
	DELTA = int(ARGS[2])
	INTEGRAL_PATHS = int(ARGS[3])
else
	NUM_PARTICLES = 1#1
	DELTA = 3#10
	INTEGRAL_PATHS = 1#2
end

#println(string("NUM_PARTICLES:", NUM_PARTICLES, " DELTA:", DELTA, " INTEGRAL_PATHS:", INTEGRAL_PATHS))

data = loadObservations()

LOOKAHEAD_DELTA = 0
ari_without_lookahead = run_sampler()
#LOOKAHEAD_DELTA = DELTA
#ari_with_lookahead = run_sampler()

#print([ari_without_lookahead, ari_with_lookahead])"""

end


