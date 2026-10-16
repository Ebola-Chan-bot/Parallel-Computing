classdef ElevatedOperation
	enumeration
		Non_ascii_hostname_parpool_fix
		Reset_Gpu
	end
	methods
		%不能用subsref，否则放在sprintf里面会无限循环UAC，导致计算机直接无法使用
		function Call(obj,varargin)
			persistent Operator
			% 把枚举成员名与参数拼成命令行调用提权操作.exe执行，参数须为数值，按空格分隔的无符号十进制文本传递
			if isempty(Operator)
				Operator=['"',fullfile(fileparts(mfilename('fullpath')),'提权操作.exe'),'" "' matlabroot '" '];
			end
			if~isempty(varargin)
				varargin={join(string([varargin{:}]),' ')};
			end
			system(sprintf('%s %s %s',Operator,obj,varargin{:}),'-runAsAdmin');
		end
	end
end