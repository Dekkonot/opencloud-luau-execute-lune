--!optimize 2
local process = require("@lune/process")
local net = require("@lune/net")
local serde = require("@lune/serde")

local API_KEY_ENV_VAR = "RBX_API_KEY"

local MAX_PAYLOAD_SIZE = 4_000_000 -- 4mb
local MAX_INPUT_SIZE = 104_857_600 -- 100 MiB
local MAX_EXECUTION_TIME = 300 -- 5 minutes

--- `await_finish` exponentially backs off querying the status of the task
--- but will stop when it's yielding this number of seconds and no longer
--- increase the time to yield
local MAX_QUERY_YIELD = 16

local BASE_URL = "https://apis.roblox.com/cloud/v2"
local TASK_CREATE_LATEST = `{BASE_URL}/universes/%s/places/%s/luau-execution-session-tasks`
local TASK_CREATE_VERSIONED = `{BASE_URL}/universes/%s/places/%s/versions/%s/luau-execution-session-tasks`
local BINARY_INPUT_CREATE = `{BASE_URL}/universes/%s/luau-execution-session-task-binary-inputs`

local USER_AGENT = `Dekkonot/Lune-OpenCloud-Execution 0.0.0; {_VERSION}`

local RATE_LIMIT_HEADER = "x-ratelimit-reset"

local api_key_override: string?

local function api_key(): string
	if api_key_override then
		return api_key_override
	else
		local api_key = process.env[API_KEY_ENV_VAR]
		if not api_key then
			error(`no Open Cloud API key specified (consider specifying one with the env var {API_KEY_ENV_VAR})`)
		else
			return api_key
		end
	end
end

export type LuauTaskState = "STATE_UNSPECIFIED" | "QUEUED" | "PROCESSING" | "CANCELLED" | "COMPLETE" | "FAILED"

export type LuauExecutionTask = {
	path: string,
	user: string,
	state: LuauTaskState,
	script: string,
	timeout: string,

	--- The path to the binary input used for this task, if one was provided.
	binaryInput: string,
	--- Whether or not the output will include a binary blob
	enableBinaryOutput: boolean,
	--- A path to the binary blob of the output
	binaryOutputUri: string,

	-- Not available upon creation, only querying

	createTime: string?,
	updateTime: string?,
	output: {
		results: { unknown },
	}?,
}

export type MessageType = "MESSAGE_TYPE_UNSPECIFIED" | "OUTPUT" | "INFO" | "WARNING" | "ERROR"

export type StructuredLog = {
	message: string,
	createTime: string,
	messageType: MessageType,
}

type LuauExecutionSessionTaskLogs = {
	luauExecutionSessionTaskLogs: {
		{
			path: string,
			messages: { string },
			structuredMessages: { StructuredLog },
		}
	},
	nextPageToken: string,
}

--- A response from uploading a binary input
type InputUploadResponse = {
	path: string,
	size: number,
	uploadUri: string,
}

function upload_input(input: buffer | string, universe_id: string): string
	local input_size = if typeof(input) == "buffer" then buffer.len(input) else #input
	if input_size > MAX_INPUT_SIZE then
		error(
			`failed to upload input: input is too large (max size is {MAX_INPUT_SIZE} bytes, your data is {input_size} bytes)`
		)
	end
	local request = {
		size = input_size,
	}

	local result = net.request({
		method = "POST",
		url = string.format(BINARY_INPUT_CREATE, universe_id),
		body = serde.encode("json", request),
		headers = {
			["User-Agent"] = USER_AGENT,
			["Content-Type"] = "application/json",
			["X-API-Key"] = api_key(),
		},
	})
	if not result.ok then
		if result.statusCode == 429 then
			error(
				`failed to upload input: {result.statusCode} {result.statusMessage}, try again in {result.headers[RATE_LIMIT_HEADER]}s`
			)
		else
			error(`failed to upload input: {result.statusCode} {result.statusMessage}. body from error:\n{result.body}`)
		end
	end
	local response: InputUploadResponse = serde.decode("json", result.body)
	print(response)

	local result_2 = net.request({
		method = "PUT",
		url = response.uploadUri,
		body = input,
		headers = {
			["User-Agent"] = USER_AGENT,
			["Content-Type"] = "application/octet-stream",
			["X-API-Key"] = api_key(),
		},
	})
	if not result_2.ok then
		error(
			`failed to upload input: {result_2.statusCode} {result_2.statusMessage}. body from error:\n{result_2.body}`
		)
	end

	return response.path
end

local function make_task(
	url: string,
	script: string,
	timeout: number?,
	enable_binary_output: boolean?,
	binary_input: string?
): LuauExecutionTask
	local request = {
		script = script,
		timeout = `{timeout}s`,
		enableBinaryOutput = enable_binary_output or false,
		binaryInput = binary_input,
	}

	local body = serde.encode("json", request)
	if #body > MAX_PAYLOAD_SIZE then
		error("failed to create task: the final size of the request is too large for Roblox to accept")
	end

	local result = net.request({
		method = "POST",
		url = url,
		body = body,
		headers = {
			["User-Agent"] = USER_AGENT,
			["Content-Type"] = "application/json",
			["X-API-Key"] = api_key(),
		},
	})

	if not result.ok then
		if result.statusCode == 429 then
			error(
				`failed to create task: {result.statusCode} {result.statusMessage}, try again in {result.headers[RATE_LIMIT_HEADER]}s`
			)
		else
			error(`failed to create task: {result.statusCode} {result.statusMessage}. body from error:\n{result.body}`)
		end
	end
	local response: LuauExecutionTask = serde.decode("json", result.body)

	return response
end

function get_logs(
	task: LuauExecutionTask,
	view: "VIEW_UNSPECIFIED" | "FLAT" | "STRUCTURED"
): LuauExecutionSessionTaskLogs
	local result = net.request({
		method = "GET",
		url = `{BASE_URL}/{task.path}/logs`,
		headers = {
			["User-Agent"] = USER_AGENT,
			["X-API-Key"] = api_key(),
		},
		query = {
			["view"] = view,
		},
	})
	if not result.ok then
		if result.statusCode == 429 then
			error(
				`failed to get task logs: {result.statusCode} {result.statusMessage}, try again in {result.headers[RATE_LIMIT_HEADER]}s`
			)
		else
			error(
				`failed to get task logs: {result.statusCode} {result.statusMessage}. body from error:\n{result.body}`
			)
		end
	end

	return serde.decode("json", result.body)
end

function query_status(task: LuauExecutionTask): LuauExecutionTask
	local result = net.request({
		method = "GET",
		url = `{BASE_URL}/{task.path}`,
		headers = {
			["User-Agent"] = USER_AGENT,
			["X-API-Key"] = api_key(),
		},
	})

	if not result.ok then
		if result.statusCode == 429 then
			error(
				`failed to check task status: {result.statusCode} {result.statusMessage}, try again in {result.headers[RATE_LIMIT_HEADER]}s`
			)
		else
			error(
				`failed to check task status: {result.statusCode} {result.statusMessage}. body from error:\n{result.body}`
			)
		end
	end

	return serde.decode("json", result.body)
end

local luau_execute = {}

--[[
    Creates a new LuauExecutionTask for the provided universe ID and place ID.
    The created task runs on the latest version of the specified place.
]]
function luau_execute.create_task_latest(
	universe_id: string,
	place_id: string,
	script: buffer | string,
	timeout: number?,
	enable_binary_output: boolean?,
	binary_input: (buffer | string)?
): LuauExecutionTask
	timeout = timeout or MAX_EXECUTION_TIME
	if timeout < 1 or timeout > MAX_EXECUTION_TIME then
		error(`specified timeout is outside of acceptable range [1, {MAX_EXECUTION_TIME}]`)
	end
	if type(script) == "buffer" then
		script = buffer.tostring(script)
	end

	local input_path
	if binary_input then
		input_path = upload_input(binary_input, universe_id)
	end

	return make_task(
		string.format(TASK_CREATE_LATEST, universe_id, place_id),
		script :: string,
		timeout :: number,
		enable_binary_output,
		input_path
	)
end

function luau_execute.check_status(task: LuauExecutionTask): LuauTaskState
	return query_status(task).state
end

function luau_execute.await_finish(task: LuauExecutionTask, timeout: number?): boolean
	timeout = timeout or MAX_EXECUTION_TIME
	local task_lib = require("@lune/task")
	local now = os.clock()
	local yield = 0.1

	local status: LuauTaskState = luau_execute.check_status(task)
	if status ~= "PROCESSING" then
		return status == "COMPLETE"
	end

	repeat
		task_lib.wait(yield)
		yield = math.min(yield * 2, MAX_QUERY_YIELD)
		status = luau_execute.check_status(task)
	until (status :: LuauTaskState) ~= "PROCESSING" or os.clock() - now >= timeout

	return (status :: LuauTaskState) == "COMPLETE"
end

function luau_execute.get_flat_logs(task: LuauExecutionTask): { string }
	local logs = get_logs(task, "FLAT")

	-- TODO: Pagination
	return logs.luauExecutionSessionTaskLogs[1].messages
end

function luau_execute.get_structured_logs(task: LuauExecutionTask): { StructuredLog }
	local logs = get_logs(task, "STRUCTURED")

	-- TODO: Pagination
	return logs.luauExecutionSessionTaskLogs[1].structuredMessages
end

function luau_execute.get_binary_output(task: LuauExecutionTask): buffer
	local status = query_status(task)
	local result = net.request({
		method = "GET",
		url = status.binaryOutputUri,
		headers = {
			["User-Agent"] = USER_AGENT,
			["X-API-Key"] = api_key(),
		},
	})

	if not result.ok then
		if result.statusCode == 429 then
			error(
				`failed to fetch input: {result.statusCode} {result.statusMessage}, try again in {result.headers[RATE_LIMIT_HEADER]}s`
			)
		else
			error(`failed to upload input: {result.statusCode} {result.statusMessage}. body from error:\n{result.body}`)
		end
	end

	return buffer.fromstring(result.body)
end

function luau_execute.get_output(task: LuauExecutionTask): { unknown }
	local status = query_status(task)
	if not status.output then
		return {}
	else
		return status.output.results
	end
end

function luau_execute.set_api_key(api_key: buffer | string)
	if type(api_key) == "buffer" then
		api_key_override = buffer.tostring(api_key)
	else
		api_key_override = api_key
	end
end

return luau_execute
