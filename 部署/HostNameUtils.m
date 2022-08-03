% HostNameUtils - A suite of utilities to provide
% functionalities associated with hostnames.

% Copyright 2014-2022 The MathWorks, Inc.
classdef HostNameUtils < handle
    
    methods ( Access = public, Static )
        
        % Find the localhost name
        function localHostName = getLocalHostName()
            persistent currentlocalHostName;
            if isempty( currentlocalHostName )
                % If the legitimate way of getting the localhostname fails, return 'localhost'.
                try
                    address = matlab.net.internal.InetAddress.getLocalHost();
                    currentlocalHostName = char( address.getHostName() );
                catch err
                    dctSchedulerMessage( 1, 'Failed to retrieve the localhost name. Reason', err );
                    currentlocalHostName = 'localhost';
                end
            end
            localHostName = currentlocalHostName;
        end
        
        % Build short version of the localhost name
        function shortLocalHostName = getShortLocalHostName()
            persistent currentShortLocalHostName;
            if isempty( currentShortLocalHostName )
                localHostName = parallel.internal.general.HostNameUtils.getLocalHostName();
                dotparts = strsplit( localHostName, '.' );
                currentShortLocalHostName = dotparts{1};
            end
            shortLocalHostName = currentShortLocalHostName;
        end
    
        % Find the canonical name of the localhost
        function localCanonicalHostName = getLocalCanonicalHostName()
            persistent currentlocalCanonicalHostName;
            if isempty( currentlocalCanonicalHostName )
				currentlocalCanonicalHostName=getenv('COMPUTERNAME');
            end
            localCanonicalHostName = currentlocalCanonicalHostName;
        end
        
        % Obtain hostname from canonical hostname
        function hostName = getHostName( canonicalHostName )
            % if the given canonicalhostname doesn't exist, little can be done here.
            try
                theHost  = matlab.net.internal.InetAddress.getByName( canonicalHostName );
                hostName = char( theHost.getHostName() );
            catch err
                errToThrow = MException( message( 'parallel:cluster:InvalidHostParameter', 'canonicalhostname' ) );
                errToThrow = errToThrow.addCause( err );
                throw( errToThrow );
            end
        end
        
        % Get canonical hostname from hostname
        function canonicalHostName = getCanonicalHostName( hostname )
            % if the given hostname doesn't exist, little can be done here.
            try
                theHost = matlab.net.internal.InetAddress.getByName( hostname );
                canonicalHostName = char( theHost.getCanonicalHostName() );
            catch err
                errToThrow = MException( message( 'parallel:cluster:InvalidHostParameter', 'hostname' ) );
                errToThrow = errToThrow.addCause( err );
                throw( errToThrow );
            end
        end
        
        % Get the IP address. This is the function most guaranteed to
        % return a unique string for each host.
        % version - Desired version of the Internet Protocol returned (4 or
        % 6). By default this is 4.
        function ipAddress = getLocalHostAddress( version )
            if nargin < 1
                version = 4;
            end
            
            persistent currentIPAddress;
            persistent currentVersion;
            
            assert(any(version == [4 6]), 'Invalid ip version specified. Valid options are 4 or 6');
            if currentVersion == version
                % Return cached ip address matching given version
                ipAddress = currentIPAddress;
                return
            end
            
            % If matlab.net.internal.InetAddress.getLocalHost throws an
            % error - resort to the network interfaces
            try
                netAddress = matlab.net.internal.InetAddress.getLocalHost();
                if ( iMatchesIPVersion( netAddress, version ) )
                    % getLocalHost() returns required ip version
                    ipAddress = char( string( netAddress ) );
                    currentIPAddress = ipAddress;
                    currentVersion = version;
                    return
                end
            catch err
                dctSchedulerMessage( 1, 'Failed to retrieve the address for the localhost via getLocalHost. Reason', err );
            end
            
            % If using network interfaces fails, error
            errToThrow = MException( message( 'parallel:internal:cluster:FailedToRetrieveHostAddress' ) );
            try
                ipAddress = iLookupHostIPAddress( version );
            catch err
                % Log, and tack onto the MATLAB exception
                dctSchedulerMessage( 1, 'Failed to retrieve the address for the localhost via NetworkInterface. Reason:', err );
                errToThrow = errToThrow.addCause( err );
            end
            if isempty( ipAddress )
                throw( errToThrow );
            end
             
             currentIPAddress = ipAddress;
             currentVersion = version;
        end
    end
    
end

function tf = iMatchesIPVersion( netAddress, version )
    tf = version == netAddress.Version;
end

function hostIP = iLookupHostIPAddress(version)
% Lookup the IP address via the network interfaces
% We use '127.0.0.1' as the fall back in case we find no better address.
% This is required to ensure that local processes which do not actually
% require a valid address can continue to work in these environments
% (g2347414).
hostIP = '127.0.0.1';
if parallel.internal.pool.isPoolThreadWorker
    % Guard against calling in to network interfaces from a thread-worker.
    % TODO(g2733379).
    return;
end
networkInterfaces = matlab.net.internal.NetworkInterface.list();
for net = networkInterfaces
    if net.IsUpAndRunning && ~net.IsLoopback
        netAddresses = net.InetAddresses;
        for netAddress = netAddresses
            if ~iCheckAnyLocalAddress(netAddress) && ...
                    ~netAddress.IsLoopback() && ...
                    ~netAddress.IsMulticast() && ....
                    iMatchesIPVersion(netAddress, version)
                hostIP = char( string( netAddress ) );
                return;
            end
        end
    end
end
end

function tf = iCheckAnyLocalAddress(address)
% Check if address is local wildcard address: '0.0.0.0'
% Default InetAddress is the wildcard address
tf = isequal(address, matlab.net.internal.InetAddress);
end