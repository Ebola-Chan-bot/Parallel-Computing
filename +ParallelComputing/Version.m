function V = Version
V.Me='v8.1.4';
V.MatlabExtension='v11.2.0';
V.MATLAB='R2022b';
persistent NewVersion
try
	if isempty(NewVersion)
		NewVersion=TextAnalytics.CheckUpdateFromGitHub('https://github.com/Silver-Fang/Parallel-Computing/releases','埃博拉酱的并行计算工具箱',V.Me);
	end
catch ME
	if ME.identifier~="MATLAB:undefinedVarOrClass"
		ME.rethrow;
	end
end