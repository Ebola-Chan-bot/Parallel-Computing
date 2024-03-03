classdef ElevatedOperation<uint8
	enumeration
		Non_ascii_hostname_parpool_fix(0)
	end
	methods
		function Call(obj,varargin)
			persistent Operator
			if isempty(Operator)
				Operator=['"',fullfile(fileparts(mfilename('fullpath')),'提权操作.exe'),'" "' matlabroot '" '];
			end
			system([Operator,char(obj),varargin{:}],'-runAsAdmin');
		end
	end
end