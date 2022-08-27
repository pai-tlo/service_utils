local schema_processor = require("schema_processor");
local rest_client_factory = require('service_utils.REST.client');
local cjson = require('cjson.safe');
local json_parser = cjson.new();
local core_utils = require("lua_schema.core_utils");
local properties_funcs = platform.properties_funcs();

local service_client = {};

local function get_api_idl_obj(product_name, module_name, class_name)

	local parts = (require "pl.stringx".split(module_name, '.'))
	local n = #parts;
	local idl_class_name = class_name .. "_interface";
	local idl_class_path = product_name;

	for i,v in ipairs(parts) do
		idl_class_path = idl_class_path.."."..v;
	end
	idl_class_path = idl_class_path.. ".idl.".. idl_class_name

	return require(idl_class_path);
end

local function get_input_json(schema_def, obj)
	local msg_handler = schema_processor:get_message_handler(schema_def.name, schema_def.ns);
	assert(msg_handler ~= nil);
	local json, msg = msg_handler:to_json(obj);
	if (json == nil) then
		error(msg);
	end
	return json;
end

local function get_output_obj(schema_def, response)
	local msg_handler = schema_processor:get_message_handler(schema_def.name, schema_def.ns);
	assert(msg_handler ~= nil);
	local obj, msg = msg_handler:from_json(response);
	if (obj == nil) then
		error(msg);
	end
	return obj;
end

service_client.get_interface_method_properties = function(context, inp)
	assert(inp.module_name ~= nil and type(inp.module_name) == 'string');
	assert(inp.class_name ~= nil and type(inp.class_name) == 'string');
	assert(inp.method_name ~= nil and type(inp.method_name) == 'string');
	assert(inp.product_name ~= nil and type(inp.product_name) == 'string');

	local interface_class = get_api_idl_obj(inp.product_name, inp.module_name, inp.class_name);
	assert(interface_class.methods ~= nil);

	local method_properties = interface_class.methods[inp.method_name];
	if (method_properties == nil) then
		error("Invalid methdod ["..inp.class_name.."] ".."["..inp.method_name.."]");
	end

	return method_properties, interface_class;
end

service_client.low_transcieve = function(context, rest_client, uri, headers, request_json)
	assert(type(headers) == 'table');
	assert(type(uri) == 'string');
	assert(type(request_json) == 'string');

    rest_client:send_request(uri, headers, request_json);

	local status, response_json, http_status = rest_client:recv_response();
	if (not status) then
		if (response_json ~= nil) then
			local obj, msg = json_parser.decode(response_json);
			if (obj == nil) then
				return false, response_json, http_status, msg;
			end
			return false, obj, http_status;
		else
			return false, nil, http_status;
		end
	end

	return status, response_json, http_status;
end

service_client.prepare_request_json = function(context, method_properties, inp)
	assert(inp.request_obj == nil or type(inp.request_obj) == 'table');
	local request_json = '';
	if (method_properties.message.in_out[1] ~= nil) then
		assert(inp.request_obj ~= nil);
		request_json = get_input_json(method_properties.message.in_out[1], inp.request_obj);
	end

	return request_json;
end

service_client.make_connection_to_internal_host = function(context, inp)
	assert(inp.service_name ~= nil and type(inp.service_name) == 'string');

	local config_conn = context.db_connections['CONFIG'].conn;
	assert(config_conn ~= nil);

	local status, response, msg = config_conn:zrangebyscore(inp.service_name, '-inf', false, '+inf', false);
	if (not status) then
		local msg = messages:format('HOST_NOT_RESOLVED_FROM_CONFIG', inp.service_name);
		error(msg);
		return false, nil;
	end

	local host_confg_rec_handler =
		schema_processor:get_message_handler('host_config_rec', 'http://evpoco.tekenlight.org/idl_spec');

	local host_config_element = host_confg_rec_handler:from_json(core_utils.str_base64_decode(response[1]));

	local client = rest_client_factory.new(host_config_element.host, tonumber(host_config_element.port));

	return client;
end

service_client.prepare_headers = function(context, inp, method_properties)
	assert(type(method_properties) == 'table');
	assert(type(inp) == 'table');

	local headers = {};
	headers.method = method_properties.http_method;
    headers['X-Auth'] = context.access_token;

	return headers;
end

service_client.prepare_uri = function(context, inp)
	assert(type(inp) == 'table');
	assert(inp.module_name ~= nil and type(inp.module_name) == 'string');
	assert(inp.product_name ~= nil and type(inp.product_name) == 'string');
	assert(inp.query_params ~= nil and type(inp.query_params) == 'table');

	local uri;
	local properties_funcs = platform.properties_funcs();
	local app_base_path_not_to_be_used = properties_funcs.get_bool_property("service_utils.REST.controller.appBasePath");
	if (app_base_path_not_to_be_used == nil) then app_base_path_not_to_be_used = true; end
	if (not app_base_path_not_to_be_used) then
		uri = "/"..inp.product_name.."/"..string.gsub(inp.module_name, "%.", "/");
	else
		uri = "/"..string.gsub(inp.module_name, "%.", "/");
	end
	uri = uri.."/"..inp.class_name.."/"..inp.method_name;
	local i = 1;
	for  n,v in pairs(inp.query_params) do
		if (i == 1) then
			uri = uri..'?';
		else
			uri = uri..'&';
		end
		i = i + 1;
		uri = uri..n.."="..tostring(v); -- To check if tostring will work for query params
	end

	return uri;
end

service_client.prepare_response_obj = function(context, method_properties, response_json)
	assert(type(method_properties) == 'table');

	if (method_properties.message.in_out[2] ~= nil) then
		assert(response_json ~= nil and type(response_json) == 'string');
		local obj, msg = get_output_obj(method_properties.message.in_out[2], response_json);
		if (obj == nil) then
			error(msg);
		end
		return obj;
	else
		return nil;
	end

	return obj;
end

service_client.transceive = function(context, inp)
	assert(context ~= nil and type(context) == 'table');
	assert(inp ~= nil and type(inp) == 'table');

	local method_properties, interface_class = service_client.get_interface_method_properties(context, inp);

	local client = service_client.make_connection_to_internal_host(context, inp);
	local uri = service_client.prepare_uri(context, inp);
	local headers = service_client.prepare_headers(context, inp, method_properties);
	local request_json = service_client.prepare_request_json(context, method_properties, inp);

	local status, response, http_status = service_client.low_transcieve(context, client, uri, headers, request_json);
	if (not status) then
		return status, response, http_status;
	end

	local response_json = response;
	local obj = service_client.prepare_response_obj(context, method_properties, response_json);

	return status, obj, http_status;
end




return service_client;

